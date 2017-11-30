{-# LANGUAGE DataKinds, MultiParamTypeClasses, ScopedTypeVariables, TypeFamilies, UndecidableInstances #-}
module Analysis.Declaration
( Declaration(..)
, HasDeclaration
, declarationAlgebra
, syntaxDeclarationAlgebra
) where

import Data.Algebra
import Data.Blob
import Data.Error (Error(..), showExpectation)
import Data.Foldable (toList)
import Data.Language as Language
import Data.List.NonEmpty (nonEmpty)
import Data.Proxy (Proxy(..))
import Data.Range
import Data.Record
import Data.Source as Source
import Data.Semigroup (sconcat)
import Data.Span
import qualified Data.Syntax as Syntax
import qualified Data.Syntax.Declaration as Declaration
import Data.Term
import qualified Data.Text as T
import Data.Union
import GHC.Generics
import Info (byteRange, sourceSpan)
import qualified Language.Markdown.Syntax as Markdown
import qualified Syntax as S

-- | A declaration’s identifier and type.
data Declaration
  = MethodDeclaration   { declarationIdentifier :: T.Text, declarationText :: T.Text, declarationLanguage :: Maybe Language, declarationReceiver :: Maybe T.Text }
  | ClassDeclaration    { declarationIdentifier :: T.Text, declarationText :: T.Text, declarationLanguage :: Maybe Language }
  | FunctionDeclaration { declarationIdentifier :: T.Text, declarationText :: T.Text, declarationLanguage :: Maybe Language }
  | HeadingDeclaration  { declarationIdentifier :: T.Text, declarationText :: T.Text, declarationLanguage :: Maybe Language, declarationLevel :: Int }
  | ErrorDeclaration    { declarationIdentifier :: T.Text, declarationText :: T.Text, declarationLanguage :: Maybe Language }
  deriving (Eq, Generic, Show)


-- | An r-algebra producing 'Just' a 'Declaration' for syntax nodes corresponding to high-level declarations, or 'Nothing' otherwise.
--
--   Customizing this for a given syntax type involves two steps:
--
--   1. Defining a 'CustomHasDeclaration' instance for the type.
--   2. Adding the type to the 'DeclarationStrategy' type family.
--
--   If you’re getting errors about missing a 'CustomHasDeclaration' instance for your syntax type, you probably forgot step 1.
--
--   If you’re getting 'Nothing' for your syntax node at runtime, you probably forgot step 2.
declarationAlgebra :: (HasField fields Range, HasField fields Span, Foldable syntax, HasDeclaration syntax) => Blob -> RAlgebra (Term syntax (Record fields)) (Maybe Declaration)
declarationAlgebra blob (In ann syntax) = toDeclaration blob ann syntax


-- | Types for which we can produce a 'Declaration' in 'Maybe'. There is exactly one instance of this typeclass; adding customized 'Declaration's for a new type is done by defining an instance of 'CustomHasDeclaration' instead.
--
--   This typeclass employs the Advanced Overlap techniques designed by Oleg Kiselyov & Simon Peyton Jones: https://wiki.haskell.org/GHC/AdvancedOverlap.
class HasDeclaration syntax where
  -- | Compute a 'Declaration' for a syntax type using its 'CustomHasDeclaration' instance, if any, or else falling back to the default definition (which simply returns 'Nothing').
  toDeclaration :: (Foldable whole, HasField fields Range, HasField fields Span) => Blob -> Record fields -> syntax (Term whole (Record fields), Maybe Declaration) -> Maybe Declaration

-- | Define 'toDeclaration' using the 'CustomHasDeclaration' instance for a type if there is one or else use the default definition.
--
--   This instance determines whether or not there is an instance for @syntax@ by looking it up in the 'DeclarationStrategy' type family. Thus producing a 'Declaration' for a node requires both defining a 'CustomHasDeclaration' instance _and_ adding a definition for the type to the 'DeclarationStrategy' type family to return 'Custom'.
--
--   Note that since 'DeclarationStrategy' has a fallback case for its final entry, this instance will hold for all types of kind @* -> *@. Thus, this must be the only instance of 'HasDeclaration', as any other instance would be indistinguishable.
instance (DeclarationStrategy syntax ~ strategy, HasDeclarationWithStrategy strategy syntax) => HasDeclaration syntax where
  toDeclaration = toDeclarationWithStrategy (Proxy :: Proxy strategy)


-- | Types for which we can produce a customized 'Declaration'. This returns in 'Maybe' so that some values can be opted out (e.g. anonymous functions).
class CustomHasDeclaration syntax where
  -- | Produce a customized 'Declaration' for a given syntax node.
  customToDeclaration :: (Foldable whole, HasField fields Range, HasField fields Span) => Blob -> Record fields -> syntax (Term whole (Record fields), Maybe Declaration) -> Maybe Declaration


-- | Produce a 'HeadingDeclaration' from the first line of the heading of a 'Markdown.Heading' node.
instance CustomHasDeclaration Markdown.Heading where
  customToDeclaration Blob{..} ann (Markdown.Heading level terms _)
    = Just $ HeadingDeclaration (headingText terms) mempty blobLanguage level
    where headingText terms = getSource $ maybe (byteRange ann) sconcat (nonEmpty (headingByteRange <$> toList terms))
          headingByteRange (Term (In ann _), _) = byteRange ann
          getSource = firstLine . toText . flip Source.slice blobSource
          firstLine = T.takeWhile (/= '\n')

-- | Produce an 'ErrorDeclaration' for 'Syntax.Error' nodes.
instance CustomHasDeclaration Syntax.Error where
  customToDeclaration Blob{..} ann err@Syntax.Error{}
    = Just $ ErrorDeclaration (T.pack (formatTOCError (Syntax.unError (sourceSpan ann) err))) mempty blobLanguage
    where formatTOCError e = showExpectation False (errorExpected e) (errorActual e) ""

-- | Produce a 'FunctionDeclaration' for 'Declaration.Function' nodes so long as their identifier is non-empty (defined as having a non-empty 'byteRange').
instance CustomHasDeclaration Declaration.Function where
  customToDeclaration blob@Blob{..} ann decl@(Declaration.Function _ (Term (In identifierAnn _), _) _ _)
    -- Do not summarize anonymous functions
    | isEmpty identifierAnn = Nothing
    -- Named functions
    | otherwise             = Just $ FunctionDeclaration (getSource identifierAnn) (getFunctionSource blob (In ann decl)) blobLanguage
    where getSource = toText . flip Source.slice blobSource . byteRange
          isEmpty = (== 0) . rangeLength . byteRange

-- | Produce a 'MethodDeclaration' for 'Declaration.Method' nodes. If the method’s receiver is non-empty (defined as having a non-empty 'byteRange'), the 'declarationIdentifier' will be formatted as 'receiver.method_name'; otherwise it will be simply 'method_name'.
instance CustomHasDeclaration Declaration.Method where
  customToDeclaration blob@Blob{..} ann decl@(Declaration.Method _ (Term (In receiverAnn receiverF), _) (Term (In identifierAnn _), _) _ _)
    -- Methods without a receiver
    | isEmpty receiverAnn = Just $ MethodDeclaration (getSource identifierAnn) (getMethodSource blob (In ann decl)) blobLanguage Nothing
    -- Methods with a receiver type and an identifier (e.g. (a *Type) in Go).
    | blobLanguage == Just Language.Go
    , [ _, Term (In receiverType _) ] <- toList receiverF = Just $ MethodDeclaration (getSource identifierAnn) (getMethodSource blob (In ann decl)) blobLanguage (Just (getSource receiverType))
    -- Methods with a receiver (class methods) are formatted like `receiver.method_name`
    | otherwise           = Just $ MethodDeclaration (getSource identifierAnn) (getMethodSource blob (In ann decl)) blobLanguage (Just (getSource receiverAnn))
    where getSource = toText . flip Source.slice blobSource . byteRange
          isEmpty = (== 0) . rangeLength . byteRange

-- | Produce a 'ClassDeclaration' for 'Declaration.Class' nodes.
instance CustomHasDeclaration Declaration.Class where
  customToDeclaration blob@Blob{..} ann decl@(Declaration.Class _ (Term (In identifierAnn _), _) _ _)
    -- Classes
    = Just $ ClassDeclaration (getSource identifierAnn) (getClassSource blob (In ann decl)) blobLanguage
    where getSource = toText . flip Source.slice blobSource . byteRange

-- | Produce a 'Declaration' for 'Union's using the 'HasDeclaration' instance & therefore using a 'CustomHasDeclaration' instance when one exists & the type is listed in 'DeclarationStrategy'.
instance Apply HasDeclaration fs => CustomHasDeclaration (Union fs) where
  customToDeclaration blob ann = apply (Proxy :: Proxy HasDeclaration) (toDeclaration blob ann)


-- | A strategy for defining a 'HasDeclaration' instance. Intended to be promoted to the kind level using @-XDataKinds@.
data Strategy = Default | Custom

-- | Produce a 'Declaration' for a syntax node using either the 'Default' or 'Custom' strategy.
--
--   You should probably be using 'CustomHasDeclaration' instead of this class; and you should not define new instances of this class.
class HasDeclarationWithStrategy (strategy :: Strategy) syntax where
  toDeclarationWithStrategy :: (Foldable whole, HasField fields Range, HasField fields Span) => proxy strategy -> Blob -> Record fields -> syntax (Term whole (Record fields), Maybe Declaration) -> Maybe Declaration


-- | A predicate on syntax types selecting either the 'Custom' or 'Default' strategy.
--
--   Only entries for which we want to use the 'Custom' strategy should be listed, with the exception of the final entry which maps all other types onto the 'Default' strategy.
--
--   If you’re seeing errors about missing a 'CustomHasDeclaration' instance for a given type, you’ve probably listed it in here but not defined a 'CustomHasDeclaration' instance for it, or else you’ve listed the wrong type in here. Conversely, if your 'customHasDeclaration' method is never being called, you may have forgotten to list the type in here.
type family DeclarationStrategy syntax where
  DeclarationStrategy Declaration.Class = 'Custom
  DeclarationStrategy Declaration.Function = 'Custom
  DeclarationStrategy Declaration.Method = 'Custom
  DeclarationStrategy Markdown.Heading = 'Custom
  DeclarationStrategy Syntax.Error = 'Custom
  DeclarationStrategy (Union fs) = 'Custom
  DeclarationStrategy a = 'Default


-- | The 'Default' strategy produces 'Nothing'.
instance HasDeclarationWithStrategy 'Default syntax where
  toDeclarationWithStrategy _ _ _ _ = Nothing

-- | The 'Custom' strategy delegates the selection of the strategy to the 'CustomHasDeclaration' instance for the type.
instance CustomHasDeclaration syntax => HasDeclarationWithStrategy 'Custom syntax where
  toDeclarationWithStrategy _ = customToDeclaration


-- | Compute 'Declaration's for methods and functions in 'Syntax'.
syntaxDeclarationAlgebra :: HasField fields Range => Blob -> RAlgebra (Term S.Syntax (Record fields)) (Maybe Declaration)
syntaxDeclarationAlgebra blob@Blob{..} decl@(In a r) = case r of
  S.Function (identifier, _) _ _ -> Just $ FunctionDeclaration (getSource identifier) (getSyntaxDeclarationSource blob decl) blobLanguage
  S.Method _ (identifier, _) Nothing _ _ -> Just $ MethodDeclaration (getSource identifier) (getSyntaxDeclarationSource blob decl) blobLanguage Nothing
  S.Method _ (identifier, _) (Just (receiver, _)) _ _
    | S.Indexed [receiverParams] <- termOut receiver
    , S.ParameterDecl (Just ty) _ <- termOut receiverParams -> Just $ MethodDeclaration (getSource identifier) (getSyntaxDeclarationSource blob decl) blobLanguage (Just (getSource ty))
    | otherwise -> Just $ MethodDeclaration (getSource identifier) (getSyntaxDeclarationSource blob decl) blobLanguage (Just (getSource receiver))
  S.ParseError{} -> Just $ ErrorDeclaration (toText (Source.slice (byteRange a) blobSource)) mempty blobLanguage
  _ -> Nothing
  where
    getSource = toText . flip Source.slice blobSource . byteRange . termAnnotation

getMethodSource :: HasField fields Range => Blob -> TermF Declaration.Method (Record fields) (Term syntax (Record fields), a) -> T.Text
getMethodSource Blob{..} (In a r)
  = let declRange = byteRange a
        bodyRange = byteRange <$> case r of
          Declaration.Method _ _ _ _ (Term (In a' _), _) -> Just a'
    in maybe mempty (T.stripEnd . toText . flip Source.slice blobSource . subtractRange declRange) bodyRange

getFunctionSource :: HasField fields Range => Blob -> TermF Declaration.Function (Record fields) (Term syntax (Record fields), a) -> T.Text
getFunctionSource Blob{..} (In a r)
  = let declRange = byteRange a
        bodyRange = byteRange <$> case r of
          Declaration.Function _ _ _ (Term (In a' _), _) -> Just a'
    in maybe mempty (T.stripEnd . toText . flip Source.slice blobSource . subtractRange declRange) bodyRange

getClassSource :: (HasField fields Range) => Blob -> TermF Declaration.Class (Record fields) (Term syntax (Record fields), a) -> T.Text
getClassSource Blob{..} (In a r)
  = let declRange = byteRange a
        bodyRange = byteRange <$> case r of
          Declaration.Class _ _ _ (Term (In a' _), _) -> Just a'
    in maybe mempty (T.stripEnd . toText . flip Source.slice blobSource . subtractRange declRange) bodyRange

getSyntaxDeclarationSource :: HasField fields Range => Blob -> TermF S.Syntax (Record fields) (Term syntax (Record fields), a) -> T.Text
getSyntaxDeclarationSource Blob{..} (In a r)
  = let declRange = byteRange a
        bodyRange = byteRange <$> case r of
          S.Function _ _ ((Term (In a' _), _) : _) -> Just a'
          S.Method _ _ _ _ ((Term (In a' _), _) : _) -> Just a'
          _ -> Nothing
    in maybe mempty (T.stripEnd . toText . flip Source.slice blobSource . subtractRange declRange) bodyRange
