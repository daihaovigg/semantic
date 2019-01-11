{-# LANGUAGE GeneralizedNewtypeDeriving, DerivingVia, PatternSynonyms, ScopedTypeVariables, UndecidableInstances #-}

module Proto3.Suite.Exts
  ( PrimitiveEnum (..)
  , pattern Present
  , pattern Absent
  , toByteString
  ) where

import Prologue

import Data.Either
import Proto3.Suite
import qualified Proto3.Wire.Encode as Encode
import qualified Proto3.Wire.Decode as Decode
import Data.ByteString.Lazy (toStrict)

pattern Present :: a -> Nested a
pattern Present t = Nested (Just t)

pattern Absent :: Nested a
pattern Absent = Nested Nothing

{-# COMPLETE Present, Absent #-}

newtype PrimitiveEnum a = PrimitiveEnum a
  deriving (Eq, Ord, Bounded, Named, Enum, HasDefault)

-- | Provides a DerivingVia hook to opt into a sensible definition of 'Primitive'
-- for a given 'Enum'. Should the decoding fail, the 'HasDefault' instance is used
-- as a fallback.
instance (Enum a, Bounded a, Named a, HasDefault a) => Primitive (PrimitiveEnum a) where
  primType _ = Named (Single (nameOf (Proxy @a)))
  encodePrimitive = Encode.enum
  decodePrimitive = fromRight def <$> Decode.enum

toByteString :: Message a => a -> ByteString
toByteString = toStrict . toLazyByteString
