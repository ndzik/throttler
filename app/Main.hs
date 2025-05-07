{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Main (main) where

import Brick
import Brick.BChan (BChan, newBChan, writeBChan)
import Brick.Util qualified as BU
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (race_)
import Control.Concurrent.STM
import Control.Exception
import Control.Lens (makeLenses, (%~), (.~), (^.))
import Control.Monad.Reader
import Data.Bifunctor (first)
import Data.ByteString.Char8 qualified as B
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Graphics.Vty qualified as V
import Graphics.Vty.Platform.Unix (mkVty)
import Network.HTTP.Client (HttpException)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Client.TLS qualified as HC
import Network.HTTP.Types
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets (ConnectionException)
import Network.WebSockets qualified as WS
import System.Environment (getArgs)
import System.Random

-- * Events

data AppEvent
  = LogMsg Text
  | ErrorMsg Text
  deriving (Show)

-- * App Environment

data ProxyConfig = ProxyConfig
  { _targetKbps :: TVar Int,
    _dropPct :: TVar Int,
    _disconnectPct :: TVar Int,
    _chunkSize :: Int,
    _port :: Int
  }

makeLenses ''ProxyConfig

type AppM = ReaderT ProxyConfig IO

-- * Throttle Logic

data SimulatedExceptions = SimulatedDisconnect | SimulatedDrop deriving (Show)

instance Exception SimulatedExceptions

throttledRequestBody :: IO B.ByteString -> AppM BL.ByteString
throttledRequestBody getChunk = go []
  where
    mkDelay cs kb = (cs * 8 * 1_000_000) `div` max 1 (kb * 1000)
    go acc = do
      chunk <- liftIO getChunk
      cfg <- ask
      kbps <- liftIO $ readTVarIO (cfg ^. targetKbps)
      dis <- liftIO $ readTVarIO (cfg ^. disconnectPct)
      let chunkSz = cfg ^. chunkSize
      if B.null chunk
        then return (BL.fromChunks (reverse acc))
        else do
          let delay = mkDelay chunkSz kbps
          r <- liftIO $ randomRIO (0, 99 :: Int)
          liftIO $ threadDelay delay
          when (r < dis) $ do
            -- Forcefully disconnect by crashing the connection.
            liftIO $ throwIO SimulatedDisconnect
          go $ chunk : acc

-- * Proxy Server

runProxyServer :: String -> BChan AppEvent -> ProxyConfig -> IO ()
runProxyServer upstreamHost chan cfg = do
  manager <- HC.newManager HC.tlsManagerSettings
  run (cfg ^. port) $ WaiWS.websocketsOr WS.defaultConnectionOptions (wsApp upstreamHost chan cfg) (app upstreamHost manager cfg chan)

-- * WAI Application

app :: String -> HC.Manager -> ProxyConfig -> BChan AppEvent -> Wai.Application
app upstreamHost manager cfg chan req respond =
  runReaderT (app' upstreamHost manager chan req respond) cfg `catch` \case
    SimulatedDisconnect -> do
      atomicallyLog chan "[Simulated] Forced client disconnect"
      respond $ Wai.responseLBS status408 corsHeaders "Simulated broken pipe"
    SimulatedDrop -> do
      atomicallyLog chan "[Simulated] Forced client disconnect"
      respond $ Wai.responseLBS status408 corsHeaders "Simulated broken pipe"

app' :: String -> HC.Manager -> BChan AppEvent -> Wai.Request -> (Wai.Response -> IO Wai.ResponseReceived) -> AppM Wai.ResponseReceived
app' upstreamHost manager chan req respond
  | Wai.requestMethod req == "OPTIONS" =
      liftIO . respond $ Wai.responseLBS status204 corsHeaders ""
  | isWebSocket req =
      liftIO . respond $ Wai.responseLBS status501 corsHeaders "WebSocket passthrough should be handled separately"
  | otherwise = do
      let rawPath = B.unpack $ Wai.rawPathInfo req
          rawQuery = B.unpack $ Wai.rawQueryString req
          fullURL = upstreamHost ++ rawPath ++ rawQuery

      liftIO . atomicallyLog chan $ "[Request] " <> T.pack (B.unpack (Wai.requestMethod req)) <> " " <> T.pack rawPath <> T.pack rawQuery

      -- Simulate full connection drop.
      cfg <- ask
      dropHood <- liftIO $ readTVarIO (cfg ^. dropPct)
      dropRoll <- liftIO $ randomRIO (0, 99 :: Int)
      when (dropRoll < dropHood) $ liftIO . throwIO $ SimulatedDrop

      body <- throttledRequestBody (Wai.getRequestBodyChunk req)

      initReq <- HC.parseRequest fullURL
      let filteredHeaders = filter (\(h, _) -> CI.foldedCase h `notElem` ["host", "content-length"]) (Wai.requestHeaders req)
          req' =
            initReq
              { HC.method = Wai.requestMethod req,
                HC.requestHeaders = filteredHeaders,
                HC.requestBody = HC.RequestBodyLBS body,
                HC.responseTimeout = HC.responseTimeoutMicro (60 * 1000000)
              }

      result <-
        liftIO $
          (Right <$> HC.httpLbs req' manager)
            `catch` ( \e -> do
                        writeBChan chan $ ErrorMsg (T.pack $ show (e :: HttpException))
                        void . liftIO . respond $ Wai.responseLBS status500 corsHeaders "Upstream request failed."
                        return (Left ())
                    )

      case result of
        Left () -> fail "Failed to send request"
        Right resp -> do
          let status = HC.responseStatus resp
              headers = HC.responseHeaders resp
              rawRespBody = HC.responseBody resp

          let ourHost = "http://127.0.0.1:" <> show (cfg ^. port)
          liftIO . respond $
            Wai.mapResponseHeaders (++ corsHeaders) $
              Wai.responseLBS status (rewriteLocationHeader upstreamHost ourHost $ stripCorsHeaders headers) rawRespBody

-- * WebSocket passthrough

wsApp :: String -> BChan AppEvent -> ProxyConfig -> WS.ServerApp
wsApp upstreamUrl chan cfg pending = do
  let req = WS.pendingRequest pending
      headers = WS.requestHeaders req
      path = WS.requestPath req
      query = maybe "" (B8.cons '?') (lookup "sec-websocket-protocol" headers)
      fullPath = path <> query

  connClient <- WS.acceptRequest pending
  let (upstreamHost, upstreamPort) = toHostPort upstreamUrl

  -- Run upstream connection and log disconnection errors.
  WS.runClient
    upstreamHost
    upstreamPort
    (B8.unpack fullPath)
    ( \connUpstream ->
        runReaderT (wsApp' connClient connUpstream) cfg
    )
    `catch` (\(_ :: ConnectionException) -> atomicallyLog chan "[WebSocket] Upstream connection closed")

wsApp' :: WS.Connection -> WS.Connection -> AppM ()
wsApp' connClient connUpstream =
  liftIO $
    race_
      (forever $ WS.receiveData connClient >>= \(t :: T.Text) -> WS.sendTextData connUpstream t)
      (forever $ WS.receiveData connUpstream >>= \(t :: T.Text) -> WS.sendTextData connClient t)

-- * Utils

isWebSocket :: Wai.Request -> Bool
isWebSocket req =
  case lookup "upgrade" (map (first CI.foldedCase) (Wai.requestHeaders req)) of
    Just val -> B8.map toLower val == "websocket"
    Nothing -> False

toHostPort :: String -> (String, Int)
toHostPort url =
  let noProto = dropWhile (/= '/') (dropWhile (/= '/') (dropWhile (/= ':') url))
      hostPort = drop 2 noProto
      (host, portStr) = break (== ':') hostPort
   in (host, read (drop 1 portStr))

rewriteLocationHeader :: String -> String -> ResponseHeaders -> ResponseHeaders
rewriteLocationHeader from to =
  map rewrite
  where
    rewrite ("Location", v)
      | B8.pack from `B8.isPrefixOf` v =
          ("Location", B8.pack to <> B8.drop (B8.length $ B8.pack from) v)
    rewrite other = other

stripCorsHeaders :: ResponseHeaders -> ResponseHeaders
stripCorsHeaders = filter (\(k, _) -> CI.foldedCase k `notElem` corsHeaderNames)

corsHeaderNames :: [B.ByteString]
corsHeaderNames =
  [ "access-control-allow-origin",
    "access-control-allow-methods",
    "access-control-allow-headers",
    "access-control-max-age"
  ]

corsHeaders :: ResponseHeaders
corsHeaders =
  [ ("Access-Control-Allow-Origin", "*"),
    ("Access-Control-Allow-Methods", "*"),
    ("Access-Control-Allow-Headers", "*"),
    ("Access-Control-Max-Age", "86400")
  ]

atomicallyLog :: BChan AppEvent -> Text -> IO ()
atomicallyLog chan msg = writeBChan chan (LogMsg msg)

-- * Brick UI

data Name = RateLimitInput | DropPercentageInput | DisconnectLikelihood | LogViewport deriving (Eq, Ord, Show)

data St = St
  { _rateLimitInput :: Editor Text Name,
    _dropPercentageInput :: Editor Text Name,
    _disconnectLikelihoodInput :: Editor Text Name,
    _logs :: [Text],
    _eventChan :: BChan AppEvent,
    _rateVar :: TVar Int,
    _currentRate :: Int,
    _dropVar :: TVar Int,
    _currentDrop :: Int,
    _disconnectVar :: TVar Int,
    _currentDisconnect :: Int,
    _availableHeight :: Int,
    _currentField :: Name
  }

makeLenses ''St

drawUI :: St -> [Widget Name]
drawUI st =
  [ vBox
      [ hLimitPercent 100 $
          vBox
            [ borderWithLabel (str "Logs") logViewport,
              hBox
                [ drawPane
                    (st ^. currentField == RateLimitInput)
                    ("Rate (KBit/s) [current: " <> showVal (st ^. currentRate) <> "]")
                    (renderEditor (txt . T.unlines) (st ^. currentField == RateLimitInput) (st ^. rateLimitInput)),
                  drawPane
                    (st ^. currentField == DropPercentageInput)
                    ("Drop (%) [0-100] [current: " <> showVal (st ^. currentDrop) <> "]")
                    (renderEditor (txt . T.unlines) (st ^. currentField == DropPercentageInput) (st ^. dropPercentageInput)),
                  drawPane
                    (st ^. currentField == DisconnectLikelihood)
                    ("Disconnect (%) [0-100] [current: " <> showVal (st ^. currentDisconnect) <> "]")
                    (renderEditor (txt . T.unlines) (st ^. currentField == DisconnectLikelihood) (st ^. disconnectLikelihoodInput))
                ],
              hBorder,
              str "<Enter>: apply highlighted configuration value. <Tab>: switch input fields. <Ctrl-Q>: quit"
            ]
      ]
  ]
  where
    logViewport =
      viewport LogViewport Vertical $
        vBox (map (txt . T.stripEnd) (reverse (st ^. logs)))
    showVal = T.unpack . T.pack . show

paneBorderMappings :: [(AttrName, V.Attr)]
paneBorderMappings =
  [ (borderAttr, V.yellow `BU.on` V.black)
  ]

-- | Helper to draw a pane with a border that changes color if selected.
drawPane :: Bool -> String -> Widget Name -> Widget Name
drawPane isSelected label content =
  if isSelected
    then updateAttrMap (applyAttrMappings paneBorderMappings) $ borderWithLabel (withAttr (attrName "label") (str label)) content
    else borderWithLabel (str label) content

handleEvent :: BrickEvent Name AppEvent -> EventM Name St ()
handleEvent ev = do
  case ev of
    AppEvent (LogMsg msg) -> do
      modify (logs %~ (msg :))
      vScrollToEnd $ viewportScroll LogViewport
    AppEvent (ErrorMsg msg) -> do
      modify (logs %~ ("[ERROR] " <> msg :))
      vScrollToEnd $ viewportScroll LogViewport
    VtyEvent (V.EvKey V.KEnter []) -> handleEditorInput =<< gets _currentField
    VtyEvent (V.EvKey (V.KChar 'q') [V.MCtrl]) -> halt
    VtyEvent (V.EvKey (V.KChar '\t') []) -> switchInput
    VtyEvent (V.EvResize _ newHeight) -> modify (availableHeight .~ newHeight)
    ev'@(VtyEvent _) ->
      gets _currentField >>= \case
        RateLimitInput -> Brick.zoom rateLimitInput $ handleEditorEvent ev'
        DropPercentageInput -> Brick.zoom dropPercentageInput $ handleEditorEvent ev'
        DisconnectLikelihood -> Brick.zoom disconnectLikelihoodInput $ handleEditorEvent ev'
        _ -> return ()
    _ -> return ()
  where
    switchInput = do
      current <- gets _currentField
      case current of
        RateLimitInput -> modify (currentField .~ DropPercentageInput)
        DropPercentageInput -> modify (currentField .~ DisconnectLikelihood)
        DisconnectLikelihood -> modify (currentField .~ RateLimitInput)
        _ -> modify (currentField .~ RateLimitInput)

handleEditorInput :: Name -> EventM Name St ()
handleEditorInput RateLimitInput = do
  input <- gets (T.strip . T.concat . getEditContents . (^. rateLimitInput))
  chan <- gets _eventChan
  rv <- gets _rateVar
  case reads (T.unpack input) of
    [(n :: Int, _)] | n > 0 -> do
      liftIO . atomically $ writeTVar rv n
      liftIO . atomicallyLog chan $ "Applied new rate limit: " <> T.pack (show n) <> " KBit/s"
      modify (rateLimitInput .~ editor RateLimitInput (Just 1) "")
      modify (currentRate .~ n)
    _ -> liftIO $ writeBChan chan $ ErrorMsg "Invalid input: expected a positive integer"
handleEditorInput DropPercentageInput = do
  input <- gets (T.strip . T.concat . getEditContents . (^. dropPercentageInput))
  chan <- gets _eventChan
  rv <- gets _dropVar
  case reads (T.unpack input) of
    [(n :: Int, _)] | n >= 0 && n <= 100 -> do
      liftIO . atomically $ writeTVar rv n
      liftIO . atomicallyLog chan $ "Applied new drop percentage: " <> T.pack (show n) <> "%"
      modify (dropPercentageInput .~ editor DropPercentageInput (Just 1) "")
      modify (currentDrop .~ n)
    _ -> liftIO $ writeBChan chan $ ErrorMsg "Invalid input: expected an integer between 0 and 100"
handleEditorInput DisconnectLikelihood = do
  input <- gets (T.strip . T.concat . getEditContents . (^. disconnectLikelihoodInput))
  chan <- gets _eventChan
  rv <- gets _disconnectVar
  case reads (T.unpack input) of
    [(n :: Int, _)] | n >= 0 && n <= 100 -> do
      liftIO . atomically $ writeTVar rv n
      liftIO . atomicallyLog chan $ "Applied new disconnect percentage: " <> T.pack (show n) <> "%"
      modify (disconnectLikelihoodInput .~ editor DisconnectLikelihood (Just 1) "")
      modify (currentDisconnect .~ n)
    _ -> liftIO $ writeBChan chan $ ErrorMsg "Invalid input: expected an integer between 0 and 100"
handleEditorInput _ = return ()

appDef :: App St AppEvent Name
appDef =
  App
    { appDraw = drawUI,
      appChooseCursor = showFirstCursor,
      appHandleEvent = handleEvent,
      appStartEvent = return (),
      appAttrMap = const theMap
    }

-- | Attribute map to highlight the selected list item and search matches.
theMap :: AttrMap
theMap =
  attrMap
    V.defAttr
    [ (attrName "bold", V.withStyle V.defAttr V.bold),
      (attrName "focused", V.withStyle (V.yellow `BU.on` V.black) V.bold),
      (attrName "label", V.withStyle (V.yellow `BU.on` V.black) V.bold)
    ]

main :: IO ()
main = do
  args <- getArgs

  case args of
    [host] -> do
      let buildVty = mkVty V.defaultConfig
      vty <- buildVty
      (_, height) <- V.displayBounds (V.outputIface vty)

      chan <- newBChan 10
      rv <- newTVarIO 2048
      dpct <- newTVarIO 0
      dv <- newTVarIO 0
      let conf =
            ProxyConfig
              { _targetKbps = rv,
                _dropPct = dpct,
                _disconnectPct = dv,
                _chunkSize = 1024,
                _port = 8888
              }
      _ <- forkIO $ runProxyServer host chan conf
      let initialState =
            St
              { _rateLimitInput = editor RateLimitInput (Just 1) "",
                _dropPercentageInput = editor DropPercentageInput (Just 1) "",
                _disconnectLikelihoodInput = editor DisconnectLikelihood (Just 1) "",
                _logs = [],
                _eventChan = chan,
                _rateVar = rv,
                _currentRate = 2048,
                _dropVar = dpct,
                _currentDrop = 0,
                _disconnectVar = dv,
                _currentDisconnect = 0,
                _availableHeight = height,
                _currentField = RateLimitInput
              }
      void $ customMain vty buildVty (Just chan) appDef initialState
    _ -> putStrLn "Usage: ./proxy <http://upstream-host>"
