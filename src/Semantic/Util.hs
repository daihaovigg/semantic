{-# LANGUAGE ConstraintKinds, Rank2Types, ScopedTypeVariables, TypeFamilies, TypeOperators #-}
{-# OPTIONS_GHC -Wno-missing-signatures -Wno-missing-export-lists #-}
module Semantic.Util where

import Prelude hiding (readFile)

import           Analysis.Abstract.Caching.FlowSensitive
import           Analysis.Abstract.Collecting
import           Control.Abstract
import           Control.Abstract.Heap (runHeapError)
import           Control.Abstract.ScopeGraph (runScopeError)
import           Control.Effect.Trace (runTraceByPrinting)
import           Control.Exception (displayException)
import           Data.Abstract.Address.Hole as Hole
import           Data.Abstract.Address.Monovariant as Monovariant
import           Data.Abstract.Address.Precise as Precise
import           Data.Abstract.Evaluatable
import           Data.Abstract.Module
import qualified Data.Abstract.ModuleTable as ModuleTable
import           Data.Abstract.Package
import           Data.Abstract.Value.Concrete as Concrete
import           Data.Abstract.Value.Type as Type
import           Data.Blob
import           Data.File
import           Data.Graph (topologicalSort)
import           Data.Graph.ControlFlowVertex
import qualified Data.Language as Language
import           Data.List (uncons)
import           Data.Project hiding (readFile)
import           Data.Quieterm (Quieterm, quieterm)
import           Data.Sum (weaken)
import           Data.Term
import qualified Language.Go.Assignment
import qualified Language.PHP.Assignment
import qualified Language.Python.Assignment
import qualified Language.Ruby.Assignment
import qualified Language.TypeScript.Assignment
import           Parsing.Parser
import           Prologue
import           Semantic.Analysis
import           Semantic.Config
import           Semantic.Graph
import           Semantic.Task
import           System.Exit (die)
import           System.FilePath.Posix (takeDirectory)

import Data.Location

-- The type signatures in these functions are pretty gnarly, but these functions
-- are hit sufficiently often in the CLI and test suite so as to merit avoiding
-- the overhead of repeated type inference. If you have to hack on these functions,
-- it's recommended to remove all the type signatures and add them back when you
-- are done (type holes in GHCi will help here).

justEvaluating :: Evaluator
                        term
                        Precise
                        (Value term Precise)
                        (ResumableC
                           (BaseError (ValueError term Precise))
                              (ResumableC
                                 (BaseError (AddressError Precise (Value term Precise)))
                                    (ResumableC
                                       (BaseError ResolutionError)
                                          (ResumableC
                                             (BaseError
                                                (EvalError term Precise (Value term Precise)))
                                                (ResumableC
                                                   (BaseError (HeapError Precise))
                                                      (ResumableC
                                                         (BaseError (ScopeError Precise))
                                                            (ResumableC
                                                               (BaseError
                                                                  (UnspecializedError
                                                                     Precise (Value term Precise)))
                                                                  (ResumableC
                                                                     (BaseError
                                                                        (LoadError
                                                                           Precise
                                                                           (Value term Precise)))
                                                                        (FreshC
                                                                              (StateC
                                                                                 (ScopeGraph
                                                                                    Precise)
                                                                                    (StateC
                                                                                       (Heap
                                                                                          Precise
                                                                                          Precise
                                                                                          (Value
                                                                                             term
                                                                                             Precise))
                                                                                          (TraceByPrintingC
                                                                                                (LiftC
                                                                                                   IO)))))))))))))
                        result
                      -> IO
                           (Heap Precise Precise (Value term Precise),
                            (ScopeGraph Precise,
                             Either
                               (SomeError
                                  (Sum
                                     '[BaseError (ValueError term Precise),
                                       BaseError (AddressError Precise (Value term Precise)),
                                       BaseError ResolutionError,
                                       BaseError (EvalError term Precise (Value term Precise)),
                                       BaseError (HeapError Precise),
                                       BaseError (ScopeError Precise),
                                       BaseError (UnspecializedError Precise (Value term Precise)),
                                       BaseError (LoadError Precise (Value term Precise))]))
                               result))
justEvaluating
  = runM
  . runEvaluator
  . raiseHandler runTraceByPrinting
  . runHeap
  . runScopeGraph
  . raiseHandler runFresh
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runScopeError
  . runHeapError
  . runEvalError
  . runResolutionError
  . runAddressError
  . runValueError

-- We can't go with the inferred type because this needs to be
-- polymorphic in @lang@.
justEvaluatingCatchingErrors :: ( hole ~ Hole (Maybe Name) Precise
                                , term ~ Quieterm (Sum lang) Location
                                , value ~ Concrete.Value term hole
                                , Apply Show1 lang
                                )
  => Evaluator term hole
       value
       (ResumableWithC
          (BaseError (ValueError term hole))
          (ResumableWithC (BaseError (AddressError hole value))
          (ResumableWithC (BaseError ResolutionError)
          (ResumableWithC (BaseError (EvalError term hole value))
          (ResumableWithC (BaseError (HeapError hole))
          (ResumableWithC (BaseError (ScopeError hole))
          (ResumableWithC (BaseError (UnspecializedError hole value))
          (ResumableWithC (BaseError (LoadError hole value))
          (FreshC
          (StateC (ScopeGraph hole)
          (StateC (Heap hole hole (Concrete.Value (Quieterm (Sum lang) Location) (Hole (Maybe Name) Precise)))
          (TraceByPrintingC
          (LiftC IO))))))))))))) a
     -> IO (Heap hole hole value, (ScopeGraph hole, a))
justEvaluatingCatchingErrors
  = runM
  . runEvaluator @_ @_ @(Value _ (Hole.Hole (Maybe Name) Precise))
  . raiseHandler runTraceByPrinting
  . runHeap
  . runScopeGraph
  . raiseHandler runFresh
  . resumingLoadError
  . resumingUnspecialized
  . resumingScopeError
  . resumingHeapError
  . resumingEvalError
  . resumingResolutionError
  . resumingAddressError
  . resumingValueError

checking
  :: Evaluator
       term
       Monovariant
       Type.Type
       (ResumableC
          (BaseError
             Type.TypeError)
             (StateC
                Type.TypeMap
                   (ResumableC
                      (BaseError
                         (AddressError
                            Monovariant
                            Type.Type))
                         (ResumableC
                            (BaseError
                               (EvalError
                                  term
                                  Monovariant
                                  Type.Type))
                               (ResumableC
                                  (BaseError
                                     ResolutionError)
                                     (ResumableC
                                        (BaseError
                                           (HeapError
                                              Monovariant))
                                           (ResumableC
                                              (BaseError
                                                 (ScopeError
                                                    Monovariant))
                                                 (ResumableC
                                                    (BaseError
                                                       (UnspecializedError
                                                          Monovariant
                                                          Type.Type))
                                                       (ResumableC
                                                          (BaseError
                                                             (LoadError
                                                                Monovariant
                                                                Type.Type))
                                                             (ReaderC
                                                                (Live
                                                                   Monovariant)
                                                                   (NonDetC
                                                                         (ReaderC
                                                                            (Cache
                                                                               term
                                                                               Monovariant
                                                                               Type.Type)
                                                                               (StateC
                                                                                  (Cache
                                                                                     term
                                                                                     Monovariant
                                                                                     Type.Type)
                                                                                     (FreshC
                                                                                           (StateC
                                                                                              (ScopeGraph
                                                                                                 Monovariant)
                                                                                                 (StateC
                                                                                                    (Heap
                                                                                                       Monovariant
                                                                                                       Monovariant
                                                                                                       Type.Type)
                                                                                                       (TraceByPrintingC
                                                                                                             (LiftC
                                                                                                                IO))))))))))))))))))
       result
     -> IO
          (Heap
             Monovariant
             Monovariant
             Type.Type,
           (ScopeGraph
              Monovariant,
            (Cache
               term
               Monovariant
               Type.Type,
             [Either
                (SomeError
                   (Sum
                      '[BaseError
                          Type.TypeError,
                        BaseError
                          (AddressError
                             Monovariant
                             Type.Type),
                        BaseError
                          (EvalError
                             term
                             Monovariant.Monovariant
                             Type.Type),
                        BaseError
                          ResolutionError,
                        BaseError
                          (HeapError
                             Monovariant),
                        BaseError
                          (ScopeError
                             Monovariant),
                        BaseError
                          (UnspecializedError
                             Monovariant
                             Type.Type),
                        BaseError
                          (LoadError
                             Monovariant
                             Type.Type)]))
                result])))
checking
  = runM
  . runEvaluator
  . raiseHandler runTraceByPrinting
  . runHeap
  . runScopeGraph
  . raiseHandler runFresh
  . caching
  . providingLiveSet
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runScopeError
  . runHeapError
  . runResolutionError
  . runEvalError
  . runAddressError
  . runTypes

type ProjectEvaluator syntax =
  Project
  -> IO
      (Heap
      (Hole (Maybe Name) Precise)
      (Hole (Maybe Name) Precise)
      (Value
      (Quieterm (Sum syntax) Location)
      (Hole (Maybe Name) Precise)),
      (ScopeGraph (Hole (Maybe Name) Precise),
      ModuleTable
      (Module
              (ModuleResult
              (Hole (Maybe Name) Precise)
              (Value
              (Quieterm (Sum syntax) Location)
              (Hole (Maybe Name) Precise))))))
type FileEvaluator syntax =
  [FilePath]
  -> IO
       (Heap
          Precise
          Precise
          (Value
             (Quieterm (Sum syntax) Location) Precise),
        (ScopeGraph Precise,
         Either
           (SomeError
              (Sum
                 '[BaseError
                     (ValueError
                        (Quieterm (Sum syntax) Location)
                        Precise),
                   BaseError
                     (AddressError
                        Precise
                        (Value
                           (Quieterm
                              (Sum syntax) Location)
                           Precise)),
                   BaseError ResolutionError,
                   BaseError
                     (EvalError
                        (Quieterm (Sum syntax) Location)
                        Precise
                        (Value
                           (Quieterm
                              (Sum syntax) Location)
                           Precise)),
                   BaseError (HeapError Precise),
                   BaseError (ScopeError Precise),
                   BaseError
                     (UnspecializedError
                        Precise
                        (Value
                           (Quieterm
                              (Sum syntax) Location)
                           Precise)),
                   BaseError
                     (LoadError
                        Precise
                        (Value
                           (Quieterm
                              (Sum syntax) Location)
                           Precise))]))
           (ModuleTable
              (Module
                 (ModuleResult
                    Precise
                    (Value
                       (Quieterm (Sum syntax) Location)
                       Precise))))))

evalGoProject :: FileEvaluator Language.Go.Assignment.Syntax
evalGoProject = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.Go) goParser

evalRubyProject :: FileEvaluator Language.Ruby.Assignment.Syntax
evalRubyProject = justEvaluating <=< evaluateProject (Proxy @'Language.Ruby)               rubyParser

evalPHPProject :: FileEvaluator Language.PHP.Assignment.Syntax
evalPHPProject  = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.PHP)        phpParser

evalPythonProject :: FileEvaluator Language.Python.Assignment.Syntax
evalPythonProject     = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.Python)     pythonParser

evalJavaScriptProject :: FileEvaluator Language.TypeScript.Assignment.Syntax
evalJavaScriptProject = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.JavaScript) typescriptParser

evalTypeScriptProject :: FileEvaluator Language.TypeScript.Assignment.Syntax
evalTypeScriptProject = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.TypeScript) typescriptParser

type FileTypechecker (syntax :: [* -> *]) qterm value address result
  = FilePath
  -> IO
       (Heap
          address
          address
          value,
        (ScopeGraph
           address,
         (Cache
            qterm
            address
            value,
          [Either
             (SomeError
                (Sum
                   '[BaseError
                       Type.TypeError,
                     BaseError
                       (AddressError
                          address
                          value),
                     BaseError
                       (EvalError
                          qterm
                          address
                          value),
                     BaseError
                       ResolutionError,
                     BaseError
                       (HeapError
                          address),
                     BaseError
                       (ScopeError
                          address),
                     BaseError
                       (UnspecializedError
                          address
                          value),
                     BaseError
                       (LoadError
                          address
                          value)]))
             result])))

typecheckGoFile :: ( syntax ~ Language.Go.Assignment.Syntax
                   , qterm ~ Quieterm (Sum syntax) Location
                   , value ~ Type
                   , address ~ Monovariant
                   , result ~ (ModuleTable (Module (ModuleResult address value))))
                => FileTypechecker syntax qterm value address result
typecheckGoFile = checking <=< evaluateProjectWithCaching (Proxy :: Proxy 'Language.Go) goParser

typecheckRubyFile :: ( syntax ~ Language.Ruby.Assignment.Syntax
                   , qterm ~ Quieterm (Sum syntax) Location
                   , value ~ Type
                   , address ~ Monovariant
                   , result ~ (ModuleTable (Module (ModuleResult address value))))
                  => FileTypechecker syntax qterm value address result
typecheckRubyFile = checking <=< evaluateProjectWithCaching (Proxy :: Proxy 'Language.Ruby) rubyParser

callGraphProject
  :: (Language.SLanguage lang, Ord1 syntax,
      Declarations1 syntax,
      Evaluatable syntax,
      FreeVariables1 syntax,
      AccessControls1 syntax,
      HasPrelude lang, Functor syntax,
      VertexDeclarationWithStrategy
        (VertexDeclarationStrategy syntax)
        syntax
        syntax) =>
     Parser
       (Term syntax Location)
     -> Proxy lang
     -> [FilePath]
     -> IO
          (Graph ControlFlowVertex,
           [Module ()])
callGraphProject parser proxy paths = runTask' $ do
  blobs <- catMaybes <$> traverse readBlobFromFile (flip File (Language.reflect proxy) <$> paths)
  package <- fmap snd <$> parsePackage parser (Project (takeDirectory (maybe "/" fst (uncons paths))) blobs (Language.reflect proxy) [])
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  x <- runCallGraph proxy False modules package
  pure (x, (() <$) <$> modules)


scopeGraphRubyProject :: ProjectEvaluator Language.Ruby.Assignment.Syntax
scopeGraphRubyProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.Ruby) rubyParser

scopeGraphPHPProject :: ProjectEvaluator Language.PHP.Assignment.Syntax
scopeGraphPHPProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.PHP) phpParser

scopeGraphGoProject :: ProjectEvaluator Language.Go.Assignment.Syntax
scopeGraphGoProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.Go) goParser

scopeGraphTypeScriptProject :: ProjectEvaluator Language.TypeScript.Assignment.Syntax
scopeGraphTypeScriptProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.TypeScript) typescriptParser

scopeGraphJavaScriptProject :: ProjectEvaluator Language.TypeScript.Assignment.Syntax
scopeGraphJavaScriptProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.TypeScript) typescriptParser


evaluatePythonProject :: ( syntax ~ Language.Python.Assignment.Syntax
                   , qterm ~ Quieterm (Sum syntax) Location
                   , value ~ (Concrete.Value qterm address)
                   , address ~ Precise
                   , result ~ (ModuleTable (Module (ModuleResult address value)))) => FilePath
     -> IO
          (Heap address address value,
           (ScopeGraph address,
             Either
                (SomeError
                   (Sum
                      '[BaseError
                          (ValueError qterm address),
                        BaseError
                          (AddressError
                             address
                             value),
                        BaseError
                          ResolutionError,
                        BaseError
                          (EvalError
                             qterm
                             address
                             value),
                        BaseError
                          (HeapError
                             address),
                        BaseError
                          (ScopeError
                             address),
                        BaseError
                          (UnspecializedError
                             address
                             value),
                        BaseError
                          (LoadError
                             address
                             value)]))
                result))
evaluatePythonProject = justEvaluating <=< evaluatePythonProjects (Proxy @'Language.Python) pythonParser Language.Python

callGraphRubyProject :: [FilePath] -> IO (Graph ControlFlowVertex, [Module ()])
callGraphRubyProject = callGraphProject rubyParser (Proxy @'Language.Ruby)

type EvalEffects qterm err = ResumableC (BaseError err)
                         (ResumableC (BaseError (AddressError Precise (Value qterm Precise)))
                         (ResumableC (BaseError ResolutionError)
                         (ResumableC (BaseError (EvalError qterm Precise (Value qterm Precise)))
                         (ResumableC (BaseError (HeapError Precise))
                         (ResumableC (BaseError (ScopeError Precise))
                         (ResumableC (BaseError (UnspecializedError Precise (Value qterm Precise)))
                         (ResumableC (BaseError (LoadError Precise (Value qterm Precise)))
                         (FreshC
                         (StateC (ScopeGraph Precise)
                         (StateC (Heap Precise Precise (Value qterm Precise))
                         (TraceByPrintingC
                         (LiftC IO))))))))))))

type LanguageSyntax lang syntax = ( Language.SLanguage lang
                                  , HasPrelude lang
                                  , Apply Eq1 syntax
                                  , Apply Ord1 syntax
                                  , Apply Show1 syntax
                                  , Apply Functor syntax
                                  , Apply Foldable syntax
                                  , Apply Evaluatable syntax
                                  , Apply Declarations1 syntax
                                  , Apply AccessControls1 syntax
                                  , Apply FreeVariables1 syntax)

evaluateProject proxy parser paths = withOptions debugOptions $ \ config logger statter ->
  evaluateProject' (TaskSession config "-" False logger statter) proxy parser paths

-- Evaluate a project consisting of the listed paths.
-- TODO: This is used by our specs and should be moved into SpecHelpers.hs
evaluateProject' session proxy parser paths = do
  res <- runTask session $ do
    blobs <- catMaybes <$> traverse readBlobFromFile (flip File (Language.reflect proxy) <$> paths)
    package <- fmap (quieterm . snd) <$> parsePackage parser (Project (takeDirectory (maybe "/" fst (uncons paths))) blobs (Language.reflect proxy) [])
    modules <- topologicalSort <$> runImportGraphToModules proxy package
    trace $ "evaluating with load order: " <> show (map (modulePath . moduleInfo) modules)
    pure (id @(Evaluator _ Precise (Value _ Precise) _ _)
         (runModuleTable
         (runModules (ModuleTable.modulePaths (packageModules package))
         (raiseHandler (runReader (packageInfo package))
         (raiseHandler (evalState (lowerBound @Span))
         (raiseHandler (runReader (lowerBound @Span))
         (evaluate proxy (runDomainEffects (evalTerm withTermSpans)) modules)))))))
  either (die . displayException) pure res

evaluatePythonProjects :: ( term ~ Term (Sum Language.Python.Assignment.Syntax) Location
                          , qterm ~ Quieterm (Sum Language.Python.Assignment.Syntax) Location
                          )
                       => Proxy 'Language.Python
                       -> Parser term
                       -> Language.Language
                       -> FilePath
                       -> IO (Evaluator qterm Precise
                               (Value qterm Precise)
                               (EvalEffects qterm (ValueError qterm Precise))
                               (ModuleTable (Module (ModuleResult Precise (Value qterm Precise)))))
evaluatePythonProjects proxy parser lang path = runTask' $ do
  project <- readProject Nothing path lang []
  package <- fmap quieterm <$> parsePythonPackage parser project
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  trace $ "evaluating with load order: " <> show (map (modulePath . moduleInfo) modules)
  pure (id @(Evaluator _ Precise (Value _ Precise) _ _)
       (runModuleTable
       (runModules (ModuleTable.modulePaths (packageModules package))
       (raiseHandler (runReader (packageInfo package))
       (raiseHandler (evalState (lowerBound @Span))
       (raiseHandler (runReader (lowerBound @Span))
       (evaluate proxy (runDomainEffects (evalTerm withTermSpans)) modules)))))))

evaluateProjectForScopeGraph :: ( term ~ Term (Sum syntax) Location
                              , qterm ~ Quieterm (Sum syntax) Location
                              , address ~ Hole (Maybe Name) Precise
                              , LanguageSyntax lang syntax
                              )
                             => Proxy (lang :: Language.Language)
                             -> Parser term
                             -> Project
                             -> IO (Evaluator qterm address
                                    (Value qterm address)
                                    (ResumableWithC (BaseError (ValueError qterm address))
                               (ResumableWithC (BaseError (AddressError address (Value qterm address)))
                               (ResumableWithC (BaseError ResolutionError)
                               (ResumableWithC (BaseError (EvalError qterm address (Value qterm address)))
                               (ResumableWithC (BaseError (HeapError address))
                               (ResumableWithC (BaseError (ScopeError address))
                               (ResumableWithC (BaseError (UnspecializedError address (Value qterm address)))
                               (ResumableWithC (BaseError (LoadError address (Value qterm address)))
                               (FreshC
                               (StateC (ScopeGraph address)
                               (StateC (Heap address address (Value qterm address))
                               (TraceByPrintingC
                               (LiftC IO)))))))))))))
                             (ModuleTable (Module
                                (ModuleResult address (Value qterm address)))))
evaluateProjectForScopeGraph proxy parser project = runTask' $ do
  package <- fmap quieterm <$> parsePythonPackage parser project
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  trace $ "evaluating with load order: " <> show (map (modulePath . moduleInfo) modules)
  pure (id @(Evaluator _ (Hole.Hole (Maybe Name) Precise) (Value _ (Hole.Hole (Maybe Name) Precise)) _ _)
       (runModuleTable
       (runModules (ModuleTable.modulePaths (packageModules package))
       (raiseHandler (runReader (packageInfo package))
       (raiseHandler (evalState (lowerBound @Span))
       (raiseHandler (runReader (lowerBound @Span))
       (evaluate proxy (runDomainEffects (evalTerm withTermSpans)) modules)))))))

evaluateProjectWithCaching :: ( term ~ Term (Sum syntax) Location
                              , qterm ~ Quieterm (Sum syntax) Location
                              , LanguageSyntax lang syntax
                              )
                           => Proxy (lang :: Language.Language)
                           -> Parser term
                          -> FilePath
                          -> IO (Evaluator qterm Monovariant Type
                                  (ResumableC (BaseError Type.TypeError)
                                  (StateC TypeMap
                                  (ResumableC (BaseError (AddressError Monovariant Type))
                                  (ResumableC (BaseError (EvalError qterm Monovariant Type))
                                  (ResumableC (BaseError ResolutionError)
                                  (ResumableC (BaseError (HeapError Monovariant))
                                  (ResumableC (BaseError (ScopeError Monovariant))
                                  (ResumableC (BaseError (UnspecializedError Monovariant Type))
                                  (ResumableC (BaseError (LoadError Monovariant Type))
                                  (ReaderC (Live Monovariant)
                                  (NonDetC
                                  (ReaderC (Analysis.Abstract.Caching.FlowSensitive.Cache (Data.Quieterm.Quieterm (Sum syntax) Data.Location.Location) Monovariant Type)
                                  (StateC (Analysis.Abstract.Caching.FlowSensitive.Cache (Data.Quieterm.Quieterm (Sum syntax) Data.Location.Location) Monovariant Type)
                                  (FreshC
                                  (StateC (ScopeGraph Monovariant)
                                  (StateC (Heap Monovariant Monovariant Type)
                                  (TraceByPrintingC
                                   (LiftC IO))))))))))))))))))
                                 (ModuleTable (Module (ModuleResult Monovariant Type))))
evaluateProjectWithCaching proxy parser path = runTask' $ do
  project <- readProject Nothing path (Language.reflect proxy) []
  package <- fmap (quieterm . snd) <$> parsePackage parser project
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  pure (id @(Evaluator _ Monovariant _ _ _)
       (raiseHandler (runReader (packageInfo package))
       (raiseHandler (evalState (lowerBound @Span))
       (raiseHandler (runReader (lowerBound @Span))
       (runModuleTable
       (runModules (ModuleTable.modulePaths (packageModules package))
       (evaluate proxy (runDomainEffects (evalTerm withTermSpans)) modules)))))))

parseFile :: Parser term -> FilePath -> IO term
parseFile parser = runTask' . (parse parser <=< readBlob . file)

blob :: FilePath -> IO Blob
blob = runTask' . readBlob . file

runTask' :: TaskEff a -> IO a
runTask' task = runTaskWithOptions debugOptions task >>= either (die . displayException) pure

mergeErrors :: Either (SomeError (Sum errs)) (Either (SomeError err) result) -> Either (SomeError (Sum (err ': errs))) result
mergeErrors = either (\ (SomeError sum) -> Left (SomeError (weaken sum))) (either (\ (SomeError err) -> Left (SomeError (inject err))) Right)

reassociate :: Either (SomeError err1) (Either (SomeError err2) (Either (SomeError err3) (Either (SomeError err4) (Either (SomeError err5) (Either (SomeError err6) (Either (SomeError err7) (Either (SomeError err8) result))))))) -> Either (SomeError (Sum '[err8, err7, err6, err5, err4, err3, err2, err1])) result
reassociate = mergeErrors . mergeErrors . mergeErrors . mergeErrors . mergeErrors . mergeErrors . mergeErrors . mergeErrors . Right
