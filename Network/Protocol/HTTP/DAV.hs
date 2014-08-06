-- DAV.hs: WebDAV client library
-- Copyright © 2012-2014  Clint Adams
--
-- vim: softtabstop=4:shiftwidth=4:expandtab
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE OverloadedStrings, ConstraintKinds, FlexibleContexts,
             QuasiQuotes, RankNTypes, GeneralizedNewtypeDeriving,
             FlexibleInstances, MultiParamTypeClasses, UndecidableInstances,
             TypeFamilies #-}

module Network.Protocol.HTTP.DAV (
    DAVT(..)
  , evalDAVT
  , setCreds
  , setDepth
  , setResponseTimeout
  , setUserAgent
  , DAVContext(..)
  , getProps
  , getPropsAndContent
  , putContentAndProps
  , putContent
  , deleteContent
  , moveContent
  , makeCollection
  , caldavReport
  , caldavReportM
  , delContentM
  , getPropsM
  , getContentM
  , withContentM
  , mkCol
  , moveContentM
  , putPropsM
  , putContentM
  , putContentM'
  , withLockIfPossible
  , withLockIfPossibleForDelete
  , module Network.Protocol.HTTP.DAV.TH
) where

import Network.Protocol.HTTP.DAV.TH

import Control.Applicative (liftA2, Applicative)
import Control.Error (EitherT(..))
import Control.Exception.Lifted (catchJust, finally, bracketOnError)
import Control.Lens ((^.), (.=), (%=))
import Control.Monad (liftM, liftM2, when, MonadPlus)
import Control.Monad.Base (MonadBase(..))
import Control.Monad.Error (MonadError)
import Control.Monad.Fix (MonadFix)
import Control.Monad.Trans (lift, MonadTrans)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.State (evalStateT, get, MonadState, StateT)
import Control.Monad.Trans.Control (MonadBaseControl(..))

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map as Map

import Data.Maybe (catMaybes, fromMaybe)

import Network.HTTP.Client (RequestBody(..), httpLbs, parseUrl, applyBasicAuth, Request(..), Response(..), newManager, closeManager, HttpException(..), BodyReader, withResponse)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (hContentType, Method, Status, RequestHeaders, unauthorized401, conflict409)

import qualified Text.XML as XML
import Text.XML.Cursor (($/), (&/), element, node, fromDocument, checkName)
import Text.Hamlet.XML (xml)

import Data.CaseInsensitive (mk)

newtype DAVT m a = DAVT { runDAVT :: EitherT String (StateT DAVContext m) a }
    deriving (Applicative, Functor, Monad, MonadBase b, MonadError String, MonadFix, MonadIO, MonadPlus, MonadState DAVContext)

instance MonadBaseControl b m => MonadBaseControl b (DAVT m) where
   newtype StM (DAVT m) a = StDAVT { unStDAVT :: StM (EitherT String (StateT DAVContext m)) a }
   liftBaseWith f = DAVT . liftBaseWith $ \r -> f $ liftM StDAVT . r . runDAVT
   restoreM       = DAVT . restoreM . unStDAVT

instance MonadTrans DAVT where
    lift = DAVT . lift . lift

evalDAVT :: MonadIO m => String -> DAVT m a -> m (Either String a)
evalDAVT u f = do
    mgr <- liftIO $ newManager tlsManagerSettings
    req <- liftIO $ parseUrl u
    r <- (evalStateT . runEitherT . runDAVT) f $ DAVContext [] req B.empty B.empty [] Nothing mgr Nothing "hDav-using application"
    liftIO $ closeManager mgr
    return r

choke :: IO (Either String a) -> IO a
choke f = do
   x <- f
   case x of
       Left e -> error e
       Right r -> return r

setCreds :: MonadIO m => B.ByteString -> B.ByteString -> DAVT m ()
setCreds u p = basicusername .= u >> basicpassword .= p

setDepth :: MonadIO m => Maybe Depth -> DAVT m ()
setDepth d = depth .= d

setUserAgent :: MonadIO m => B.ByteString -> DAVT m ()
setUserAgent ua = userAgent .= ua

setResponseTimeout :: MonadIO m => Maybe Int -> DAVT m ()
setResponseTimeout rt = baseRequest %= \x -> x { responseTimeout = rt }

mkDavRequest :: MonadIO m => Method -> RequestHeaders -> RequestBody -> DAVT m Request
mkDavRequest meth addlhdrs rbody = do
    ctx <- get
    let hdrs = catMaybes
               [ Just (mk "User-Agent", ctx ^. userAgent)
               , fmap ((,) (mk "Depth") . BC8.pack . show) (ctx ^. depth)
               ] ++ addlhdrs
        req = (ctx ^. baseRequest) { method = meth, requestHeaders = hdrs, requestBody = rbody }
        authreq = if B.null (ctx ^. basicusername) && B.null (ctx ^. basicpassword)
            then req
            else applyBasicAuth (ctx ^. basicusername) (ctx ^. basicpassword) req
    return authreq

davRequest :: MonadIO m => Method -> RequestHeaders -> RequestBody -> DAVT m (Response BL.ByteString)
davRequest meth addlhdrs rbody = go =<< mkDavRequest meth addlhdrs rbody
  where
    go req = do
      ctx <- get
      liftIO (httpLbs req (ctx ^. httpManager))

matchStatusCodeException :: Status -> HttpException -> Maybe ()
matchStatusCodeException want (StatusCodeException s _ _)
    | s == want = Just ()
    | otherwise = Nothing
matchStatusCodeException _ _ = Nothing

emptyBody :: RequestBody
emptyBody = RequestBodyLBS BL.empty

xmlBody :: XML.Document -> RequestBody
xmlBody = RequestBodyLBS . XML.renderLBS XML.def

getOptions :: MonadIO m => DAVT m ()
getOptions = do
    optresp <- davRequest "OPTIONS" [] emptyBody
    let meths = (B.splitWith (==(fromIntegral . fromEnum) ',') . fromMaybe B.empty . lookup "Allow" . responseHeaders) optresp
    let cclass = (B.splitWith (==(fromIntegral . fromEnum) ',') . fromMaybe B.empty . lookup "DAV" . responseHeaders) optresp
    complianceClasses .= cclass
    allowedMethods .= meths

lockResource :: MonadIO m => Bool -> DAVT m ()
lockResource nocreate = do
    let ahs' = [(hContentType, "application/xml; charset=\"utf-8\""), (mk "Depth", "0"), (mk "Timeout", "Second-300")]
    let ahs = if nocreate then (mk "If-Match", "*"):ahs' else ahs'
    lockresp <- davRequest "LOCK" ahs (xmlBody locky)
    let hdrtoken = (lookup "Lock-Token" . responseHeaders) lockresp
    lockToken .= hdrtoken

unlockResource :: MonadIO m => DAVT m ()
unlockResource = do
    d <- get
    case _lockToken d of
        Nothing -> return ()
	Just tok -> do let ahs = [(mk "Lock-Token", tok)]
                       _ <- davRequest "UNLOCK" ahs emptyBody
                       lockToken .= Nothing

supportsLocking :: DAVContext -> Bool
supportsLocking = liftA2 (&&) ("LOCK" `elem`) ("UNLOCK" `elem`) . _allowedMethods

supportsCalDAV :: DAVContext -> Bool
supportsCalDAV = ("calendar-access" `elem`) . _complianceClasses

getPropsM :: MonadIO m => DAVT m XML.Document
getPropsM = do
    let ahs = [(hContentType, "application/xml; charset=\"utf-8\"")]
    propresp <- davRequest "PROPFIND" ahs (xmlBody propname)
    return $ (XML.parseLBS_ XML.def . responseBody) propresp

-- | Note that the entire request body is buffered in memory.
-- To stream large files use withContentM instead.
getContentM :: MonadIO m => DAVT m (Maybe B.ByteString, BL.ByteString)
getContentM = do
    resp <- davRequest "GET" [] emptyBody
    let ct = lookup hContentType (responseHeaders resp)
    return (ct, responseBody resp)

withContentM :: MonadIO m => (Response BodyReader -> IO a) -> DAVT m a
withContentM handleresponse = do
    req <- mkDavRequest "GET" [] emptyBody
    ctx <- get
    liftIO $ withResponse req (ctx ^. httpManager) handleresponse

-- | Note that the entire request body is buffered in memory; not suitable
-- for large files.
putContentM :: MonadIO m => (Maybe B.ByteString, BL.ByteString) -> DAVT m ()
putContentM (ct, body) = putContentM' (ct, RequestBodyLBS body)

-- | To send a large file, pass eg a RequestBodyStream containing the
-- file's content.
putContentM' :: MonadIO m => (Maybe B.ByteString, RequestBody) -> DAVT m ()
putContentM' (ct, requestbody) = do
    d <- get
    let ahs' = maybe [] (return . (,) (mk "If") . parenthesize) (d ^. lockToken)
    let ahs = ahs' ++ maybe [] (return . (,) hContentType) ct
    _ <- davRequest "PUT" ahs requestbody
    return ()

delContentM :: MonadIO m => DAVT m ()
delContentM = do
    _ <- davRequest "DELETE" [] emptyBody
    return ()

moveContentM :: MonadIO m => B.ByteString -> DAVT m ()
moveContentM newurl = do
    let ahs = [ (mk "Destination", newurl) ]
    _ <- davRequest "MOVE" ahs emptyBody
    return ()

mkCol' :: MonadIO m => DAVT m ()
mkCol' = do
    _ <- davRequest "MKCOL" [] emptyBody
    return ()

mkCol :: (MonadIO m, MonadBase IO m, MonadBaseControl IO m) => DAVT m Bool
mkCol = catchJust
        (matchStatusCodeException conflict409)
        (mkCol' >> return True)
        (\_ -> return False)

parenthesize :: B.ByteString -> B.ByteString
parenthesize x = B.concat ["(", x, ")"]

putPropsM :: MonadIO m => XML.Document -> DAVT m ()
putPropsM props = do
    d <- get
    let ah' = (hContentType, "application/xml; charset=\"utf-8\"")
    let ahs = ah':maybe [] (return . (,) (mk "If") . parenthesize) (_lockToken d)
    _ <- davRequest "PROPPATCH" ahs ((RequestBodyLBS . props2patch) props) -- FIXME: should diff and remove props from target
    return ()

props2patch :: XML.Document -> BL.ByteString
props2patch = XML.renderLBS XML.def . patch . props . fromDocument
   where
       props cursor = map node (cursor $/ element "{DAV:}response" &/ element "{DAV:}propstat" &/ element "{DAV:}prop" &/ checkName (not . flip elem blacklist))
       patch prop = XML.Document (XML.Prologue [] Nothing []) (root prop) []
       root [] = propertyupdate []
       root prop = propertyupdate
           [ XML.NodeElement $ XML.Element "D:set" Map.empty
	     [ XML.NodeElement $ XML.Element "D:prop" Map.empty prop ]
	   ]
       propertyupdate = XML.Element "D:propertyupdate" (Map.fromList [("xmlns:D", "DAV:")])
       blacklist = [ "{DAV:}creationdate"
                   , "{DAV:}displayname"
                   , "{DAV:}getcontentlength"
                   , "{DAV:}getcontenttype"
                   , "{DAV:}getetag"
                   , "{DAV:}getlastmodified"
                   , "{DAV:}lockdiscovery"
                   , "{DAV:}resourcetype"
                   , "{DAV:}supportedlock"
                   ]

caldavReportM :: MonadIO m => DAVT m XML.Document
caldavReportM = do
    let ahs = [(hContentType, "application/xml; charset=\"utf-8\"")]
    calrresp <- davRequest "REPORT" ahs (xmlBody calendarquery)
    return $ (XML.parseLBS_ XML.def . responseBody) calrresp

getOptionsOnce :: MonadIO m => DAVT m ()
getOptionsOnce = getOptions -- this should only happen once

withLockIfPossible :: (MonadIO m, MonadBase IO m, MonadBaseControl IO m) => Bool -> DAVT m a -> DAVT m a
withLockIfPossible nocreate f = do
    getOptionsOnce
    o <- get
    when (supportsLocking o) (lockResource nocreate)
    f `finally` when (supportsLocking o) unlockResource

withLockIfPossibleForDelete :: (MonadIO m, MonadBase IO m, MonadBaseControl IO m) => Bool -> DAVT m a -> DAVT m a
withLockIfPossibleForDelete nocreate f = do
    getOptionsOnce
    o <- get
    let lock = when (supportsLocking o) (lockResource nocreate)
    -- a successful delete destroys locks, so only unlock on error
    let unlock = when (supportsLocking o) unlockResource
    bracketOnError lock (const unlock) (const f)

{-# DEPRECATED getProps "This function will be removed in favor of getPropsM" #-}
getProps :: String -> B.ByteString -> B.ByteString -> Maybe Depth -> IO XML.Document
getProps url username password md = choke $ evalDAVT url $ do
    setCreds username password
    setDepth md
    getPropsM

{-# DEPRECATED getPropsAndContent "This function will be removed in favor of getPropsM and getContentM" #-}
getPropsAndContent :: String -> B.ByteString -> B.ByteString -> IO (XML.Document, (Maybe B.ByteString, BL.ByteString))
getPropsAndContent url username password = choke $ evalDAVT url $ do
    setCreds username password
    setDepth (Just Depth0)
    withLockIfPossible True $ liftM2 (,) getPropsM getContentM

{-# DEPRECATED putContent "This function will be removed in favor of putContentM" #-}
putContent :: String -> B.ByteString -> B.ByteString -> (Maybe B.ByteString, BL.ByteString) -> IO ()
putContent url username password b = choke $ evalDAVT url $ do
    setCreds username password
    withLockIfPossible False $ putContentM b

{-# DEPRECATED putContentAndProps "This function will be removed in favor of putContentM and putPropsM" #-}
putContentAndProps :: String -> B.ByteString -> B.ByteString -> (XML.Document, (Maybe B.ByteString, BL.ByteString)) -> IO ()
putContentAndProps url username password (p, b) = choke $ evalDAVT url $ do
    setCreds username password
    withLockIfPossible False $ do putContentM b
                                  putPropsM p

{-# DEPRECATED deleteContent "This function will be removed in favor of delContentM" #-}
deleteContent :: String -> B.ByteString -> B.ByteString -> IO ()
deleteContent url username password = choke $ evalDAVT url $ do
    setCreds username password
    withLockIfPossibleForDelete False delContentM

{-# DEPRECATED moveContent "This function will be removed in favor of moveContentM" #-}
moveContent :: String -> B.ByteString -> B.ByteString -> B.ByteString -> IO ()
moveContent url newurl username password = choke $ evalDAVT url $ do
    setCreds username password
    moveContentM newurl

{-# DEPRECATED caldavReport "This function will be removed in favor of caldavReportM" #-}
caldavReport :: String -> B.ByteString -> B.ByteString -> IO XML.Document
caldavReport url username password = choke $ evalDAVT url $ do
   setCreds username password
   setDepth (Just Depth1)
   caldavReportM

-- | Creates a WebDAV collection, which is similar to a directory.
--
-- Returns False if the collection could not be made due to an intermediate
-- collection not existing. (Ie, collection /a/b/c/d cannot be made until
-- collection /a/b/c exists.)
{-# DEPRECATED makeCollection "This function will be removed in favor of mkCol" #-}
makeCollection :: String -> B.ByteString -> B.ByteString -> IO Bool
makeCollection url username password = choke $ evalDAVT url $ do
    setCreds username password
    mkCol

propname :: XML.Document
propname = XML.Document (XML.Prologue [] Nothing []) root []
    where
        root = XML.Element "D:propfind" (Map.fromList [("xmlns:D", "DAV:")]) [xml|
<D:allprop>
|]

locky :: XML.Document
locky = XML.Document (XML.Prologue [] Nothing []) root []
    where
        root = XML.Element "D:lockinfo" (Map.fromList [("xmlns:D", "DAV:")]) [xml|
<D:lockscope>
  <D:exclusive>
<D:locktype>
  <D:write>
<D:owner>Haskell DAV user
|]

calendarquery :: XML.Document
calendarquery = XML.Document (XML.Prologue [] Nothing []) root []
    where
        root = XML.Element "C:calendar-query" (Map.fromList [("xmlns:D", "DAV:"),("xmlns:C", "urn:ietf:params:xml:ns:caldav")]) [xml|
<D:prop>
  <D:getetag>
  <C:calendar-data>
<C:filter>
  <C:comp-filter name="VCALENDAR">
|]
