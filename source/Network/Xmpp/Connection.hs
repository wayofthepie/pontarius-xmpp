{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Xmpp.Connection where

import           Control.Applicative((<$>))
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
--import Control.Monad.Trans.Resource
import qualified Control.Exception.Lifted as Ex
import qualified GHC.IO.Exception as GIE
import           Control.Monad.State.Strict

import           Data.ByteString as BS
import           Data.Conduit
import           Data.Conduit.Binary as CB
import           Data.Conduit.BufferedSource
import qualified Data.Conduit.List as CL
import           Data.IORef
import           Data.Text(Text)
import           Data.XML.Pickle
import           Data.XML.Types

import           Network
import           Network.Xmpp.Types
import           Network.Xmpp.Marshal
import           Network.Xmpp.Pickle

import           System.IO

import           Text.XML.Stream.Elements
import           Text.XML.Stream.Parse as XP
import           Text.XML.Unresolved(InvalidEventStream(..))

-- Enable/disable debug output
-- This will dump all incoming and outgoing network taffic to the console,
-- prefixed with "in: " and "out: " respectively
debug :: Bool
debug = False

pushElement :: Element -> XmppConMonad Bool
pushElement x = do
    send <- gets (cSend . sCon)
    liftIO . send $ renderElement x

-- | Encode and send stanza
pushStanza :: Stanza -> XmppConMonad Bool
pushStanza = pushElement . pickleElem xpStanza

-- XML documents and XMPP streams SHOULD be preceeded by an XML declaration.
-- UTF-8 is the only supported XMPP encoding. The standalone document
-- declaration (matching "SDDecl" in the XML standard) MUST NOT be included in
-- XMPP streams. RFC 6120 defines XMPP only in terms of XML 1.0.
pushXmlDecl :: XmppConMonad Bool
pushXmlDecl = do
    con <- gets sCon
    liftIO $ (cSend con) "<?xml version='1.0' encoding='UTF-8' ?>"

pushOpenElement :: Element -> XmppConMonad Bool
pushOpenElement e = do
    sink <- gets (cSend . sCon )
    liftIO . sink $ renderOpenElement e

-- `Connect-and-resumes' the given sink to the connection source, and pulls a
-- `b' value.
pullToSinkEvents :: Sink Event IO b -> XmppConMonad b
pullToSinkEvents snk = do
    source <- gets (cEventSource . sCon)
    r <- lift $ source .$$+ snk
    return r

pullElement :: XmppConMonad Element
pullElement = do
    Ex.catches (do
        e <- pullToSinkEvents (elements =$ await)
        case e of
            Nothing -> liftIO $ Ex.throwIO StreamConnectionError
            Just r -> return r
        )
        [ Ex.Handler (\StreamEnd -> Ex.throwIO StreamStreamEnd)
        , Ex.Handler (\(InvalidXmppXml s)
                     -> liftIO . Ex.throwIO $ StreamXMLError s)
        , Ex.Handler $ \(e :: InvalidEventStream)
                     -> liftIO . Ex.throwIO $ StreamXMLError (show e)

        ]

-- Pulls an element and unpickles it.
pullPickle :: PU [Node] a -> XmppConMonad a
pullPickle p = do
    res <- unpickleElem p <$> pullElement
    case res of
        Left e -> liftIO . Ex.throwIO $ StreamXMLError (show e)
        Right r -> return r

-- | Pulls a stanza (or stream error) from the stream. Throws an error on a stream
-- error.
pullStanza :: XmppConMonad Stanza
pullStanza = do
    res <- pullPickle xpStreamStanza
    case res of
        Left e -> liftIO . Ex.throwIO $ StreamError e
        Right r -> return r

-- Performs the given IO operation, catches any errors and re-throws everything
-- except 'ResourceVanished' and IllegalOperation, in which case it will return False instead
catchSend :: IO () -> IO Bool
catchSend p = Ex.catch
    (p >> return True)
    (\e -> case GIE.ioe_type e of
         GIE.ResourceVanished -> return False
         GIE.IllegalOperation -> return False
         _ -> Ex.throwIO e
    )

-- -- XmppConnection state used when there is no connection.
xmppNoConnection :: XmppConnection
xmppNoConnection = XmppConnection
               { sCon             = Connection { cSend = \_ -> return False
                                               , cRecv = \_ -> Ex.throwIO
                                                           $ StreamConnectionError
                                               , cEventSource = undefined
                                               , cFlush = return ()
                                               , cClose = return ()
                                               }
               , sFeatures        = SF Nothing [] []
               , sConnectionState = XmppConnectionClosed
               , sHostname        = Nothing
               , sJid             = Nothing
               , sStreamLang      = Nothing
               , sStreamId        = Nothing
               , sPreferredLang   = Nothing
               , sToJid           = Nothing
               , sJidWhenPlain    = False
               , sFrom            = Nothing
               }
  where
    zeroSource :: Source IO output
    zeroSource = liftIO . Ex.throwIO $ StreamConnectionError

-- Connects to the given hostname on port 5222 (TODO: Make this dynamic) and
-- updates the XmppConMonad XmppConnection state.
xmppConnectTCP :: HostName -> PortID -> Text -> XmppConMonad ()
xmppConnectTCP host port hostname = do
    hand <- liftIO $ do
        h <- connectTo host port
        hSetBuffering h NoBuffering
        return h
    eSource <- liftIO . bufferSource $ (sourceHandle hand) $= XP.parseBytes def
    let con = Connection { cSend = if debug
                                    then \d -> do
                                        BS.putStrLn (BS.append "out: " d)
                                        catchSend $ BS.hPut hand d
                                    else catchSend . BS.hPut hand
                          , cRecv = if debug then
                                      \n -> do
                                          bs <- BS.hGetSome hand n
                                          BS.putStrLn bs
                                          return bs
                                    else BS.hGetSome hand
                          , cEventSource = eSource
                          , cFlush = hFlush hand
                          , cClose = hClose hand
                          }
    let st = XmppConnection
            { sCon             = con
            , sFeatures        = (SF Nothing [] [])
            , sConnectionState = XmppConnectionPlain
            , sHostname        = (Just hostname)
            , sJid             = Nothing
            , sPreferredLang   = Nothing -- TODO: Allow user to set
            , sStreamLang      = Nothing
            , sStreamId        = Nothing
            , sToJid           = Nothing -- TODO: Allow user to set
            , sJidWhenPlain    = False -- TODO: Allow user to set
            , sFrom            = Nothing
            }
    put st

-- Execute a XmppConMonad computation.
xmppNewSession :: XmppConMonad a -> IO (a, XmppConnection)
xmppNewSession action = runStateT action xmppNoConnection

-- Closes the connection and updates the XmppConMonad XmppConnection state.
xmppKillConnection :: XmppConMonad (Either Ex.SomeException ())
xmppKillConnection = do
    cc <- gets (cClose . sCon)
    err <- liftIO $ (Ex.try cc :: IO (Either Ex.SomeException ()))
    put xmppNoConnection
    return err

xmppReplaceConnection :: XmppConnection -> XmppConMonad (Either Ex.SomeException ())
xmppReplaceConnection newCon = do
    cc <- gets (cClose . sCon)
    err <- liftIO $ (Ex.try cc :: IO (Either Ex.SomeException ()))
    put newCon
    return err

-- Sends an IQ request and waits for the response. If the response ID does not
-- match the outgoing ID, an error is thrown.
xmppSendIQ' :: StanzaId
            -> Maybe Jid
            -> IQRequestType
            -> Maybe LangTag
            -> Element
            -> XmppConMonad (Either IQError IQResult)
xmppSendIQ' iqID to tp lang body = do
    pushStanza . IQRequestS $ IQRequest iqID Nothing to lang tp body
    res <- pullPickle $ xpEither xpIQError xpIQResult
    case res of
        Left e -> return $ Left e
        Right iq' -> do
            unless
                (iqID == iqResultID iq') . liftIO . Ex.throwIO $
                    StreamXMLError
                ("In xmppSendIQ' IDs don't match: " ++ show iqID ++ " /= " ++
                    show (iqResultID iq') ++ " .")
            return $ Right iq'

-- | Send "</stream:stream>" and wait for the server to finish processing and to
-- close the connection. Any remaining elements from the server and whether or
-- not we received a </stream:stream> element from the server is returned.
xmppCloseStreams :: XmppConMonad ([Element], Bool)
xmppCloseStreams = do
    send <- gets (cSend . sCon)
    cc <- gets (cClose . sCon)
    liftIO $ send "</stream:stream>"
    void $ liftIO $ forkIO $ do
        threadDelay 3000000
        (Ex.try cc) :: IO (Either Ex.SomeException ())
        return ()
    collectElems []
  where
    -- Pulls elements from the stream until the stream ends, or an error is
    -- raised.
    collectElems :: [Element] -> XmppConMonad ([Element], Bool)
    collectElems elems = do
        result <- Ex.try pullElement
        case result of
            Left StreamStreamEnd -> return (elems, True)
            Left _ -> return (elems, False)
            Right elem -> collectElems (elem:elems)

debugConduit :: Pipe l ByteString ByteString u IO b
debugConduit = forever $ do
    s <- await
    case s of
        Just s ->  do
            liftIO $ BS.putStrLn (BS.append "in: " s)
            yield s
        Nothing -> return ()