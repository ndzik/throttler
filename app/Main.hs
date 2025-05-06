{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race_)
import Control.Exception (catch)
import Control.Monad (forever, void, when)
import Data.Bifunctor (first)
import Data.ByteString.Char8 qualified as B
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (toLower)
import Data.Text qualified as Text
import Network.HTTP.Client (HttpException)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Client.TLS qualified as HC
import Network.HTTP.Types
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import System.Environment (getArgs)
import System.Random (randomRIO)

-- Configuration
delayPerChunk :: Int
delayPerChunk = 50_000 -- microseconds

chunkSize :: Int
chunkSize = 1024 -- 1 KB per chunk

packetLossChance :: Float
packetLossChance = 0.0 -- e.g., 0.1 = 10% chance

main :: IO ()
main = do
  args <- getArgs
  case args of
    [host] -> do
      let port = 8888
      putStrLn $ "Starting throttled proxy on " ++ show port ++ " forwarding requests to " ++ host
      manager <- HC.newManager HC.tlsManagerSettings
      run port $ WaiWS.websocketsOr WS.defaultConnectionOptions (wsApp host) (app host manager)
    _ -> putStrLn "Usage: ./proxy <https://upstream-host>"

rewriteLocationHeader :: String -> String -> ResponseHeaders -> ResponseHeaders
rewriteLocationHeader from to =
  map rewrite
  where
    rewrite ("Location", v)
      | B8.pack from `B8.isPrefixOf` v =
          ("Location", B8.pack to <> B8.drop (B8.length $ B8.pack from) v)
    rewrite other = other

corsHeaderNames :: [B.ByteString]
corsHeaderNames =
  [ "access-control-allow-origin",
    "access-control-allow-methods",
    "access-control-allow-headers",
    "access-control-max-age"
  ]

stripCorsHeaders :: ResponseHeaders -> ResponseHeaders
stripCorsHeaders = filter (\(k, _) -> CI.foldedCase k `notElem` corsHeaderNames)

corsHeaders :: ResponseHeaders
corsHeaders =
  [ ("Access-Control-Allow-Origin", "*"),
    ("Access-Control-Allow-Methods", "*"),
    ("Access-Control-Allow-Headers", "*"),
    ("Access-Control-Max-Age", "86400")
  ]

hasBodyMethod :: Method -> Bool
hasBodyMethod m = m `elem` ["POST", "PUT", "PATCH"]

isWebSocket :: Wai.Request -> Bool
isWebSocket req =
  case lookup "upgrade" (map (first CI.foldedCase) (Wai.requestHeaders req)) of
    Just val -> B8.map toLower val == "websocket"
    Nothing -> False

app :: String -> HC.Manager -> Wai.Application
app upstreamHost manager req respond
  | Wai.requestMethod req == "OPTIONS" = do
      putStrLn "[CORS] Handling preflight OPTIONS request"
      respond $ Wai.responseLBS status204 corsHeaders ""
  | isWebSocket req = do
      putStrLn "[WebSocket] Passing through unthrottled"
      respond $ Wai.responseLBS status501 corsHeaders "WebSocket passthrough should be handled separately"
  | otherwise = do
      let rawPath = B.unpack $ Wai.rawPathInfo req
          rawQuery = B.unpack $ Wai.rawQueryString req
          fullURL = upstreamHost ++ rawPath ++ rawQuery

      putStrLn $ "[Request] " ++ B.unpack (Wai.requestMethod req) ++ " " ++ rawPath ++ rawQuery
      putStrLn $ "[Forwarding to] " ++ fullURL

      -- Throttle the request body as it is received
      body <- Wai.strictRequestBody req
      throttledBody <- throttleChunks $ BL.toStrict body

      -- Forward the fully buffered and throttled body to upstream
      initReq <- HC.parseRequest fullURL
      let filteredHeaders =
            filter (\(h, _) -> CI.foldedCase h `notElem` ["host", "content-length"]) (Wai.requestHeaders req)

          req' =
            initReq
              { HC.method = Wai.requestMethod req,
                HC.requestHeaders = filteredHeaders,
                HC.requestBody = HC.RequestBodyLBS throttledBody,
                HC.responseTimeout = HC.responseTimeoutMicro (60 * 1000000)
              }

      putStrLn "[Headers]"
      mapM_ (putStrLn . ("  " ++) . show) (Wai.requestHeaders req)

      result <-
        (Right <$> HC.httpLbs req' manager)
          `catch` ( \e -> do
                      putStrLn $ "[ERROR] Upstream request failed: " ++ show (e :: HttpException)
                      void . respond $
                        Wai.mapResponseHeaders (++ corsHeaders) $
                          Wai.responseLBS
                            status500
                            [("Content-Type", "text/plain")]
                            "Upstream request failed.\n"
                      return (Left ())
                  )

      case result of
        Left () -> fail "Request failed"
        Right resp -> do
          let status = HC.responseStatus resp
              headers = HC.responseHeaders resp
              rawRespBody = HC.responseBody resp

          let respStrict = BL.toStrict rawRespBody
          putStrLn $ "[Response] " ++ show (statusCode status)
          B.putStrLn $ B.take 2048 respStrict
          when (B.length respStrict > 2048) $
            putStrLn "[Response Body Truncated]"

          respond $
            Wai.mapResponseHeaders (++ corsHeaders) $
              Wai.responseLBS status (rewriteLocationHeader upstreamHost "http://127.0.0.1:8888" $ stripCorsHeaders headers) rawRespBody

throttleChunks :: B.ByteString -> IO BL.ByteString
throttleChunks body = do
  putStrLn $ "[Throttle] Enabled: " ++ show chunkSize ++ " bytes per " ++ show delayPerChunk ++ "μs (~" ++ show kbps ++ "Kbit/s)"
  BL.concat <$> mapM maybeDelayAndSend chunked
  where
    kbps :: Int
    kbps = (chunkSize * 8 * 1_000_000) `div` (delayPerChunk * 1000)
    chunked = map BL.fromStrict $ chunkBytes body

    chunkBytes bs
      | B.null bs = []
      | otherwise = let (c, rest) = B.splitAt chunkSize bs in c : chunkBytes rest

    maybeDelayAndSend _chunk = do
      threadDelay delayPerChunk
      r <- randomRIO (0.0, 1.0 :: Float)
      if r < packetLossChance
        then do
          putStrLn "[Throttle] Dropped a chunk"
          return BL.empty
        else do
          putStrLn $ "[Throttle] Sent " ++ show (BL.length _chunk) ++ " bytes"
          return _chunk

-- Actual WebSocket passthrough
wsApp :: String -> WS.ServerApp
wsApp upstreamUrl pending = do
  let req = WS.pendingRequest pending
      headers = WS.requestHeaders req
      path = WS.requestPath req
      query = maybe "" (B8.cons '?') (lookup "sec-websocket-protocol" headers)
      fullPath = path <> query

  putStrLn $ "[WebSocket] Upgrading and proxying: " ++ B8.unpack fullPath

  connClient <- WS.acceptRequest pending
  let (upstreamHost, upstreamPort) = toHostPort upstreamUrl

  WS.runClient upstreamHost upstreamPort (B8.unpack fullPath) $ \connUpstream -> do
    putStrLn "[WebSocket] Connected to upstream"
    race_
      (forever $ WS.receiveData connClient >>= \(t :: Text.Text) -> WS.sendTextData connUpstream t)
      (forever $ WS.receiveData connUpstream >>= \(t :: Text.Text) -> WS.sendTextData connClient t)

toHostPort :: String -> (String, Int)
toHostPort url =
  let noProto = dropWhile (/= '/') (dropWhile (/= '/') (dropWhile (/= ':') url))
      hostPort = drop 2 noProto -- remove "//"
      (host, portStr) = break (== ':') hostPort
   in (host, read (drop 1 portStr))
