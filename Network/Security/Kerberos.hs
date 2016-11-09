{-# LANGUAGE EmptyDataDecls           #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiWayIf               #-}

module Network.Security.Kerberos (
  krb5Login
) where

import           Control.Exception     (Exception, bracket, throwIO)
import qualified Data.ByteString.Char8 as BS
import           Foreign
import           Foreign.C.String
import           Foreign.C.Types
import Control.Monad (when)

data KerberosCTX
data KerberosPrincipal

data GSSException = KrbException Int String
  deriving (Show)
instance Exception GSSException

type Context = Ptr KerberosCTX
type Principal = ForeignPtr KerberosPrincipal

foreign import ccall unsafe "krb5.h krb5_init_context"
  _krb5_init_context :: Ptr (Ptr KerberosCTX) -> IO CInt

foreign import ccall unsafe "krb5.h krb5_free_context"
  _krb5_free_context :: Ptr KerberosCTX -> IO ()

krb5_init_context :: IO Context
krb5_init_context =
  alloca $ \nptr -> do
    code <- _krb5_init_context nptr
    if | code == 0 -> peek nptr
       | otherwise -> throwIO (KrbException (fromIntegral code) "Cannot initialize kerberos context.")

withKrbContext :: (Context -> IO a) -> IO a
withKrbContext = bracket krb5_init_context _krb5_free_context

foreign import ccall unsafe "krb5.h krb5_parse_name"
  _krb5_parse_name :: Ptr KerberosCTX -> CString -> Ptr (Ptr KerberosPrincipal) -> IO CInt

foreign import ccall unsafe "krb5.h &krb5_free_principal"
  _krb5_free_principal :: FinalizerEnvPtr KerberosCTX KerberosPrincipal

krb5_parse_name :: Context -> BS.ByteString -> IO Principal
krb5_parse_name ctx name =
  alloca $ \nprincipal ->
    BS.useAsCString name $ \cname -> do
      code <- _krb5_parse_name ctx cname nprincipal
      ptr <- peek nprincipal
      if | code == 0 -> newForeignPtrEnv _krb5_free_principal ctx ptr
         | otherwise -> krb5_throw ctx code

foreign import ccall unsafe "krb5.h krb5_get_error_message"
  _krb5_get_error_message :: Ptr KerberosCTX -> CInt -> IO CString
foreign import ccall unsafe "krb5.h krb5_free_error_message"
  _krb5_free_error_message :: Ptr KerberosCTX -> CString -> IO ()

krb5_throw :: Context -> CInt -> IO a
krb5_throw ctx code = do
    ctxt <- _krb5_get_error_message ctx code
    errtext <- BS.unpack <$> BS.packCString ctxt
    _krb5_free_error_message ctx ctxt
    throwIO (KrbException (fromIntegral code) errtext)

foreign import ccall safe "hkrb5.h _hkrb5_login"
  _krb5_login :: Ptr KerberosCTX -> Ptr KerberosPrincipal -> CString -> IO CInt

krb5_login :: Context -> Principal -> BS.ByteString -> IO ()
krb5_login ctx principal password = do
  code <- withForeignPtr principal $ \ptrprincipal ->
      BS.useAsCString password $ \cpass ->
          _krb5_login ctx ptrprincipal cpass
  when (code /= 0) $ krb5_throw ctx code

krb5Login :: BS.ByteString -> BS.ByteString -> IO ()
krb5Login svcname password =
  withKrbContext $ \ctx -> do
      principal <- krb5_parse_name ctx svcname
      krb5_login ctx principal password