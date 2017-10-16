-- MonoLocalBinds is to silence a warning about a simplifiable constraint.
{-# LANGUAGE DataKinds, MonoLocalBinds, TypeOperators #-}
module Semantic.Util where

import Control.Monad.IO.Class
import Data.Blob
import Files
import Data.Record
import Data.Syntax.Algebra (HasCyclomaticComplexity, CyclomaticComplexity(..), cyclomaticComplexityAlgebra, fToR)
import Data.Functor.Classes
import Algorithm
import Data.Align.Generic
import Interpreter
import Parser
import Data.Functor.Both
import Data.Term
import Data.Diff
import Semantic
import Semantic.Task
import Renderer.TOC
import Data.Range
import Data.Span

file :: MonadIO m => FilePath -> m Blob
file path = Files.readFile path (languageForFilePath path)

diffWithParser :: (HasField fields Data.Span.Span,
                   HasField fields Range,
                   Eq1 syntax, Show1 syntax,
                   Traversable syntax, Functor syntax,
                   Foldable syntax, Diffable syntax,
                   GAlign syntax, HasDeclaration syntax, HasCyclomaticComplexity syntax)
                  =>
                  Parser (Term syntax (Record fields))
                  -> Both Blob
                  -> Task (Diff syntax (Record (CyclomaticComplexity ': Maybe Declaration ': fields)) (Record (CyclomaticComplexity ': Maybe Declaration ': fields)))
diffWithParser parser = run (\ blob -> parse parser blob >>= decorate (declarationAlgebra blob) >>= decorate (fToR cyclomaticComplexityAlgebra))
  where
    run parse sourceBlobs = distributeFor sourceBlobs parse >>= runBothWith (diffTermPair sourceBlobs diffTerms)
