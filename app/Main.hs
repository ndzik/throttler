{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Brick
import Brick.BChan (BChan, newBChan, writeBChan)
import Brick.Focus (focusGetCurrent)
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (race_)
import Control.Concurrent.STM
import Control.Exception (catch)
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
    _port :: Int
  }

makeLenses ''ProxyConfig

type AppM = ReaderT ProxyConfig IO

-- * Throttle Logic

throttleChunks :: Int -> Int -> B.ByteString -> IO BL.ByteString
throttleChunks kbps pct body = do
  let chunkSize = 1024
      delay = (chunkSize * 8 * 1_000_000) `div` (kbps * 1000)
      chunks = chunkBody chunkSize body
  BL.concat <$> mapM (throttleOne delay pct) chunks
  where
    chunkBody n bs
      | B.null bs = []
      | otherwise = let (c, rest) = B.splitAt n bs in c : chunkBody n rest

    throttleOne d _pct bs = do
      dropChance <- randomRIO (0, 99 :: Int)
      threadDelay d
      return $ if dropChance < _pct then BL.empty else BL.fromStrict bs

-- * Proxy Server

runProxyServer :: String -> BChan AppEvent -> ProxyConfig -> IO ()
runProxyServer upstreamHost chan cfg = do
  manager <- HC.newManager HC.tlsManagerSettings
  -- atomicallyLog chan $ "Starting throttled proxy on " <> (T.pack . show $ port) <> " forwarding requests to " <> T.pack upstreamHost
  run (cfg ^. port) $ WaiWS.websocketsOr WS.defaultConnectionOptions (wsApp upstreamHost cfg) (app upstreamHost manager cfg chan)

-- * WAI Application

app :: String -> HC.Manager -> ProxyConfig -> BChan AppEvent -> Wai.Application
app upstreamHost manager cfg chan req respond = runReaderT (app' upstreamHost manager chan req respond) cfg

app' :: String -> HC.Manager -> BChan AppEvent -> Wai.Request -> (Wai.Response -> IO Wai.ResponseReceived) -> AppM Wai.ResponseReceived
app' upstreamHost manager chan req respond
  | Wai.requestMethod req == "OPTIONS" =
      liftIO . respond $ Wai.responseLBS status204 corsHeaders ""
  | isWebSocket req =
      liftIO . respond $ Wai.responseLBS status501 corsHeaders "WebSocket passthrough should be handled separately"
  | otherwise = do
      cfg <- ask
      let rawPath = B.unpack $ Wai.rawPathInfo req
          rawQuery = B.unpack $ Wai.rawQueryString req
          fullURL = upstreamHost ++ rawPath ++ rawQuery

      liftIO . atomicallyLog chan $ "[Request] " <> T.pack (B.unpack (Wai.requestMethod req)) <> " " <> T.pack rawPath <> T.pack rawQuery

      body <- liftIO $ Wai.strictRequestBody req
      kbps <- liftIO $ readTVarIO (cfg ^. targetKbps)
      pct <- liftIO $ readTVarIO (cfg ^. dropPct)
      throttledBody <- liftIO $ throttleChunks kbps pct $ B.concat $ BL.toChunks body

      initReq <- HC.parseRequest fullURL
      let filteredHeaders = filter (\(h, _) -> CI.foldedCase h `notElem` ["host", "content-length"]) (Wai.requestHeaders req)

          req' =
            initReq
              { HC.method = Wai.requestMethod req,
                HC.requestHeaders = filteredHeaders,
                HC.requestBody = HC.RequestBodyLBS throttledBody,
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

          liftIO . respond $
            Wai.mapResponseHeaders (++ corsHeaders) $
              Wai.responseLBS status (rewriteLocationHeader upstreamHost "http://127.0.0.1:8888" $ stripCorsHeaders headers) rawRespBody

-- * WebSocket passthrough

wsApp :: String -> ProxyConfig -> WS.ServerApp
wsApp upstreamUrl cfg pending = do
  let req = WS.pendingRequest pending
      headers = WS.requestHeaders req
      path = WS.requestPath req
      query = maybe "" (B8.cons '?') (lookup "sec-websocket-protocol" headers)
      fullPath = path <> query

  connClient <- WS.acceptRequest pending
  let (upstreamHost, upstreamPort) = toHostPort upstreamUrl

  WS.runClient upstreamHost upstreamPort (B8.unpack fullPath) $ \connUpstream -> runReaderT (wsApp' connClient connUpstream) cfg

wsApp' :: WS.Connection -> WS.Connection -> AppM ()
wsApp' connClient connUpstream = do
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

data Name = RateLimitInput | DropPercentageInput | LogViewport deriving (Eq, Ord, Show)

data St = St
  { _rateLimitInput :: Editor Text Name,
    _dropPercentageInput :: Editor Text Name,
    _logs :: [Text],
    _eventChan :: BChan AppEvent,
    _rateVar :: TVar Int,
    _availableHeight :: Int,
    _currentField :: Name
  }

makeLenses ''St

drawUI :: St -> [Widget Name]
drawUI st =
  [ vBox
      [ hLimitPercent 100 $
          vBox
            [ vBox
                [ borderWithLabel (str "Logs") logViewport,
                  hBorder
                ],
              hBox
                [ borderWithLabel (str "Rate (KBit/s)") $ renderEditor (txt . T.unlines) (st ^. currentField == RateLimitInput) (st ^. rateLimitInput),
                  borderWithLabel (str "Drop (%) [0-100]") $ renderEditor (txt . T.unlines) (st ^. currentField == DropPercentageInput) (st ^. dropPercentageInput)
                ],
              padTop (Pad 1) $ str "<Enter>: apply highlighted configuration value. <Ctrl-N>: switch input fields. <Ctrl-Q>: quit"
            ]
      ]
  ]
  where
    logViewport =
      viewport LogViewport Vertical $
        vBox (map (txt . T.stripEnd) (reverse (st ^. logs)))

handleEvent :: BrickEvent Name AppEvent -> EventM Name St ()
handleEvent ev = do
  chan <- gets _eventChan
  rv <- gets _rateVar
  case ev of
    AppEvent (LogMsg msg) -> modify \s -> s {_logs = msg : _logs s}
    AppEvent (ErrorMsg msg) -> modify \s -> s {_logs = "[ERROR]" <> msg : _logs s}
    VtyEvent (V.EvKey V.KEnter []) -> do
      input <- gets (T.strip . T.concat . getEditContents . (^. rateLimitInput))
      case reads (T.unpack input) of
        [(n :: Int, _)] | n > 0 -> do
          liftIO . atomically $ writeTVar rv n
          liftIO . atomicallyLog chan $ "Applied new rate limit: " <> T.pack (show n) <> " KBit/s"
          modify (rateLimitInput .~ editor RateLimitInput (Just 1) "")
        _ -> liftIO $ writeBChan chan $ ErrorMsg "Invalid input: expected a positive integer"
    VtyEvent (V.EvKey (V.KChar 'q') [V.MCtrl]) -> halt
    VtyEvent (V.EvKey (V.KChar 'n') [V.MCtrl]) -> do
      current <- gets _currentField
      case current of
        RateLimitInput -> do modify (currentField .~ DropPercentageInput)
        DropPercentageInput -> modify (currentField .~ RateLimitInput)
        _ -> modify (currentField .~ RateLimitInput)
    VtyEvent (V.EvResize _ newHeight) -> modify $ \s -> s {_availableHeight = newHeight}
    ev'@(VtyEvent _) ->
      gets _currentField >>= \case
        RateLimitInput -> Brick.zoom rateLimitInput $ handleEditorEvent ev'
        DropPercentageInput -> Brick.zoom dropPercentageInput $ handleEditorEvent ev'
        _ -> return ()
    _ -> return ()

appDef :: App St AppEvent Name
appDef =
  App
    { appDraw = drawUI,
      appChooseCursor = showFirstCursor,
      appHandleEvent = handleEvent,
      appStartEvent = return (),
      appAttrMap = const $ attrMap V.defAttr []
    }

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
      let conf = ProxyConfig rv dpct 8888
      _ <- forkIO $ runProxyServer host chan conf
      let initialState =
            St
              { _rateLimitInput = editor RateLimitInput (Just 1) "",
                _dropPercentageInput = editor DropPercentageInput (Just 1) "",
                _logs = [],
                _eventChan = chan,
                _rateVar = rv,
                _availableHeight = height,
                _currentField = RateLimitInput
              }
      void $ customMain vty buildVty (Just chan) appDef initialState
    _ -> putStrLn "Usage: ./proxy <http://upstream-host>"
