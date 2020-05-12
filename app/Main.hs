{-# LANGUAGE DataKinds #-}

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

{-# LANGUAGE OverloadedLabels #-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

{-# LANGUAGE TypeOperators #-}

module Main where

import           Calamity
import           Calamity.Cache.InMemory
import           Calamity.Metrics.Eff
import           Calamity.Metrics.Internal
import           Calamity.Metrics.Noop

import           Control.Concurrent
import           Control.Concurrent.STM.TVar
import           Control.Lens
import           Control.Monad

import           Data.HashMap.Lazy                          as LH
import           Data.IORef
import           Data.Text                                  ( Text )
import           Data.Text.Lazy.Lens
import qualified Data.Vector                                as V

import qualified DiPolysemy                                 as DiP

import           GHC.Generics

import qualified Polysemy                                   as P
import qualified Polysemy.Async                             as P
import qualified Polysemy.AtomicState                       as P
import qualified Polysemy.Embed                             as P
import qualified Polysemy.Fail                              as P

import           Prelude                                    hiding ( error )

import           System.Environment
import qualified System.Metrics.Prometheus.Http.Scrape      as M
import qualified System.Metrics.Prometheus.Metric.Counter   as M
import qualified System.Metrics.Prometheus.Metric.Gauge     as M
import qualified System.Metrics.Prometheus.Metric.Histogram as M
import qualified System.Metrics.Prometheus.MetricId         as M
import qualified System.Metrics.Prometheus.Registry         as MR

import           TextShow

data CounterEff m a where
  GetCounter :: CounterEff m Int

P.makeSem ''CounterEff

runCounterAtomic :: P.Member (P.Embed IO) r => P.Sem (CounterEff ': r) () -> P.Sem r ()
runCounterAtomic m = do
  var <- P.embed $ newIORef (0 :: Int)
  P.runAtomicStateIORef var $ P.reinterpret (\case
                                              GetCounter -> P.atomicState (\v -> (v + 1, v))) m

data PrometheusMetricsState = PrometheusMetricsState
  { registry             :: MR.Registry
  , registeredCounters   :: LH.HashMap (Text, [(Text, Text)]) Counter
  , counters             :: V.Vector M.Counter
  , registeredGauges     :: LH.HashMap (Text, [(Text, Text)]) Gauge
  , gauges               :: V.Vector M.Gauge
  , registeredHistograms :: LH.HashMap (Text, [(Text, Text)], [Double]) Histogram
  , histograms           :: V.Vector M.Histogram
  }

translateH :: M.HistogramSample -> HistogramSample
translateH M.HistogramSample { M.histBuckets, M.histSum, M.histCount } = HistogramSample histBuckets histSum histCount

runMetricsPrometheusIO :: P.Member (P.Embed IO) r => P.Sem (MetricEff ': r) a -> P.Sem r a
runMetricsPrometheusIO m = do
  var <- P.embed $ newIORef $ PrometheusMetricsState MR.new mempty mempty mempty mempty mempty mempty
  P.embed . forkIO $ M.serveHttpTextMetrics 6699 ["metrics"] (readIORef var >>= MR.sample . registry)
  P.runAtomicStateIORef var $ P.reinterpret
    (\case
       RegisterCounter name labels -> do
         state <- P.atomicGet
         case LH.lookup (name, labels) (registeredCounters state) of
           Just counter -> pure counter
           Nothing      -> do
             (counterP, registry') <- P.embed $ MR.registerCounter (M.Name name) (M.fromList labels) (registry state)
             let idx = V.length $ counters state
             let counter = Counter idx
             P.atomicModify
               (\state -> state { registry           = registry'
                                , counters           = V.snoc (counters state) counterP
                                , registeredCounters = LH.insert (name, labels) counter (registeredCounters state) })
             pure counter

       RegisterGauge name labels -> do
         state <- P.atomicGet
         case LH.lookup (name, labels) (registeredGauges state) of
           Just gauge -> pure gauge
           Nothing      -> do
             (gaugeP, registry') <- P.embed $ MR.registerGauge (M.Name name) (M.fromList labels) (registry state)
             let idx = V.length $ gauges state
             let gauge = Gauge idx
             P.atomicModify
               (\state -> state { registry         = registry'
                                , gauges           = V.snoc (gauges state) gaugeP
                                , registeredGauges = LH.insert (name, labels) gauge (registeredGauges state) })
             pure gauge

       RegisterHistogram name labels bounds -> do
         state <- P.atomicGet
         case LH.lookup (name, labels, bounds) (registeredHistograms state) of
           Just histogram -> pure histogram
           Nothing      -> do
             (histogramP, registry') <- P.embed $ MR.registerHistogram (M.Name name) (M.fromList labels) bounds (registry state)
             let idx = V.length $ histograms state
             let histogram = Histogram idx
             P.atomicModify
               (\state -> state { registry             = registry'
                                , histograms           = V.snoc (histograms state) histogramP
                                , registeredHistograms = LH.insert (name, labels, bounds) histogram (registeredHistograms state) })
             pure histogram

       AddCounter by (Counter id) -> P.atomicGets counters >>= (M.unCounterSample <$>) . P.embed . M.addAndSample by . (V.! id)
       ModifyGauge f (Gauge id) -> P.atomicGets gauges >>= (M.unGaugeSample <$>) . P.embed . M.modifyAndSample f . (V.! id)
       ObserveHistogram val (Histogram id) -> P.atomicGets histograms >>= (translateH <$>) . P.embed . M.observeAndSample val . (V.! id)
    ) m


handleFailByLogging m = do
  r <- P.runFail m
  case r of
    Left e -> DiP.error (e ^. packed)
    _      -> pure ()

handleFailByPrinting m = do
  r <- P.runFail m
  case r of
    Left e -> P.embed $ print (show e)
    _      -> pure ()

info = DiP.info @Text
debug = DiP.info @Text

tellt :: (BotC r, Tellable t) => t -> Text -> P.Sem r (Either RestError Message)
tellt = tell @Text

main :: IO ()
main = do
  token <- view packed <$> getEnv "BOT_TOKEN"
  P.runFinal . P.embedToFinal . handleFailByPrinting . runCounterAtomic . runCacheInMemory . runMetricsPrometheusIO
    $ runBotIO (BotToken token) $ do
    react @'MessageCreateEvt $ \msg -> handleFailByLogging $ case msg ^. #content of
      "!count" -> replicateM_ 3 $ do
        val <- getCounter
        info $ "the counter is: " <> showt val
        void $ tellt msg ("The value is: " <> showt val)
      "!say hi" -> replicateM_ 3 . P.async $ do
        info "saying heya"
        Right msg' <- tellt msg "heya"
        info "sleeping"
        P.embed $ threadDelay (5 * 1000 * 1000)
        info "slept"
        void . invoke $ EditMessage (msg ^. #channelID) msg' (Just "lol") Nothing
        info "edited"
      "!explode" -> do
        Just x <- pure Nothing
        debug "unreachable!"
      "!bye" -> do
        void $ tellt msg "bye!"
        stopBot
      "!fire-evt" -> fire $ customEvt @"my-event" ("aha" :: Text, msg)
    react @('CustomEvt "my-event" (Text, Message)) $ \(s, m) ->
      void $ tellt m ("Somebody told me to tell you about: " <> s)
