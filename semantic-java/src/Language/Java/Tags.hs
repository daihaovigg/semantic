{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Language.Java.Tags
  ( ToTags (..),
  )
where

import AST.Element
import AST.Token
import AST.Traversable1
import Control.Effect.Reader
import Control.Effect.Writer
import Data.Foldable
import qualified Language.Java.AST as Java
import Proto.Semantic as P
import Source.Loc
import Source.Range
import Source.Source as Source
import Tags.Tag
import qualified Tags.Tagging.Precise as Tags

class ToTags t where
  tags ::
    ( Has (Reader Source) sig m,
      Has (Writer Tags.Tags) sig m
    ) =>
    t Loc ->
    m ()
  default tags ::
    ( Has (Reader Source) sig m,
      Has (Writer Tags.Tags) sig m,
      Traversable1 ToTags t
    ) =>
    t Loc ->
    m ()
  tags = gtags

instance (ToTags l, ToTags r) => ToTags (l :+: r) where
  tags (L1 l) = tags l
  tags (R1 r) = tags r

instance ToTags (Token sym n) where tags _ = pure ()

instance ToTags Java.MethodDeclaration where
  tags
    t@Java.MethodDeclaration
      { ann = Loc {byteRange = range},
        name = Java.Identifier {text, ann},
        body
      } = do
      src <- ask @Source
      let line =
            Tags.firstLine
              src
              range
                { end = case body of
                    Just Java.Block {ann = Loc Range {end} _} -> end
                    Nothing -> end range
                }
      Tags.yield (Tag text P.METHOD P.DEFINITION ann line Nothing)
      gtags t

-- TODO: we can coalesce a lot of these instances given proper use of HasField
-- to do the equivalent of type-generic pattern-matching.

instance ToTags Java.ClassDeclaration where
  tags
    t@Java.ClassDeclaration
      { ann = Loc {byteRange = Range {start}},
        name = Java.Identifier {text, ann},
        body = Java.ClassBody {ann = Loc Range {start = end} _}
      } = do
      src <- ask @Source
      Tags.yield (Tag text P.CLASS P.DEFINITION ann (Tags.firstLine src (Range start end)) Nothing)
      gtags t

instance ToTags Java.MethodInvocation where
  tags
    t@Java.MethodInvocation
      { ann = Loc {byteRange = range},
        name = Java.Identifier {text, ann}
      } = do
      src <- ask @Source
      Tags.yield (Tag text P.CALL P.REFERENCE ann (Tags.firstLine src range) Nothing)
      gtags t

instance ToTags Java.InterfaceDeclaration where
  tags
    t@Java.InterfaceDeclaration
      { ann = Loc {byteRange},
        name = Java.Identifier {text, ann}
      } = do
      src <- ask @Source
      Tags.yield (Tag text P.INTERFACE P.DEFINITION ann (Tags.firstLine src byteRange) Nothing)
      gtags t

instance ToTags Java.InterfaceTypeList where
  tags t@Java.InterfaceTypeList {extraChildren = interfaces} = do
    src <- ask @Source
    for_ interfaces $ \x -> case x of
      Java.Type (Prj (Java.UnannotatedType (Prj (Java.SimpleType (Prj Java.TypeIdentifier {ann = loc@Loc {byteRange = range}, text = name}))))) ->
        Tags.yield (Tag name P.IMPLEMENTATION P.REFERENCE loc (Tags.firstLine src range) Nothing)
      _ -> pure ()
    gtags t

gtags ::
  ( Has (Reader Source) sig m,
    Has (Writer Tags.Tags) sig m,
    Traversable1 ToTags t
  ) =>
  t Loc ->
  m ()
gtags = traverse1_ @ToTags (const (pure ())) tags

instance ToTags Java.AnnotatedType
instance ToTags Java.Annotation
instance ToTags Java.AnnotationArgumentList
instance ToTags Java.AnnotationTypeBody
instance ToTags Java.AnnotationTypeDeclaration
instance ToTags Java.AnnotationTypeElementDeclaration
instance ToTags Java.ArgumentList
instance ToTags Java.ArrayAccess
instance ToTags Java.ArrayCreationExpression
instance ToTags Java.ArrayInitializer
instance ToTags Java.ArrayType
instance ToTags Java.AssertStatement
instance ToTags Java.AssignmentExpression
instance ToTags Java.Asterisk
instance ToTags Java.BinaryExpression
instance ToTags Java.BinaryIntegerLiteral
instance ToTags Java.Block
instance ToTags Java.BooleanType
instance ToTags Java.BreakStatement
instance ToTags Java.CastExpression
instance ToTags Java.CatchClause
instance ToTags Java.CatchFormalParameter
instance ToTags Java.CatchType
instance ToTags Java.CharacterLiteral
instance ToTags Java.ClassBody
-- instance ToTags Java.ClassDeclaration
instance ToTags Java.ClassLiteral
instance ToTags Java.ConstantDeclaration
instance ToTags Java.ConstructorBody
instance ToTags Java.ConstructorDeclaration
instance ToTags Java.ContinueStatement
instance ToTags Java.DecimalFloatingPointLiteral
instance ToTags Java.DecimalIntegerLiteral
instance ToTags Java.Declaration
instance ToTags Java.Dimensions
instance ToTags Java.DimensionsExpr
instance ToTags Java.DoStatement
instance ToTags Java.ElementValueArrayInitializer
instance ToTags Java.ElementValuePair
instance ToTags Java.EnhancedForStatement
instance ToTags Java.EnumBody
instance ToTags Java.EnumBodyDeclarations
instance ToTags Java.EnumConstant
instance ToTags Java.EnumDeclaration
instance ToTags Java.ExplicitConstructorInvocation
instance ToTags Java.Expression
instance ToTags Java.ExpressionStatement
instance ToTags Java.ExtendsInterfaces
instance ToTags Java.False
instance ToTags Java.FieldAccess
instance ToTags Java.FieldDeclaration
instance ToTags Java.FinallyClause
instance ToTags Java.FloatingPointType
instance ToTags Java.ForInit
instance ToTags Java.ForStatement
instance ToTags Java.FormalParameter
instance ToTags Java.FormalParameters
instance ToTags Java.GenericType
instance ToTags Java.HexFloatingPointLiteral
instance ToTags Java.HexIntegerLiteral
instance ToTags Java.Identifier
instance ToTags Java.IfStatement
instance ToTags Java.ImportDeclaration
instance ToTags Java.InferredParameters
instance ToTags Java.InstanceofExpression
instance ToTags Java.IntegralType
instance ToTags Java.InterfaceBody
--instance ToTags Java.InterfaceDeclaration
-- instance ToTags Java.InterfaceTypeList
instance ToTags Java.LabeledStatement
instance ToTags Java.LambdaExpression
instance ToTags Java.Literal
instance ToTags Java.LocalVariableDeclaration
instance ToTags Java.LocalVariableDeclarationStatement
instance ToTags Java.MarkerAnnotation
-- instance ToTags Java.MethodDeclaration
-- instance ToTags Java.MethodInvocation
instance ToTags Java.MethodReference
instance ToTags Java.Modifiers
instance ToTags Java.ModuleDeclaration
instance ToTags Java.ModuleDirective
instance ToTags Java.ModuleName
instance ToTags Java.NullLiteral
instance ToTags Java.ObjectCreationExpression
instance ToTags Java.OctalIntegerLiteral
instance ToTags Java.PackageDeclaration
instance ToTags Java.ParenthesizedExpression
instance ToTags Java.Primary
instance ToTags Java.Program
instance ToTags Java.ReceiverParameter
instance ToTags Java.RequiresModifier
instance ToTags Java.Resource
instance ToTags Java.ResourceSpecification
instance ToTags Java.ReturnStatement
instance ToTags Java.ScopedIdentifier
instance ToTags Java.ScopedTypeIdentifier
instance ToTags Java.SimpleType
instance ToTags Java.SpreadParameter
instance ToTags Java.Statement
instance ToTags Java.StaticInitializer
instance ToTags Java.StringLiteral
instance ToTags Java.Super
instance ToTags Java.SuperInterfaces
instance ToTags Java.Superclass
instance ToTags Java.SwitchBlock
instance ToTags Java.SwitchLabel
instance ToTags Java.SwitchStatement
instance ToTags Java.SynchronizedStatement
instance ToTags Java.TernaryExpression
instance ToTags Java.This
instance ToTags Java.ThrowStatement
instance ToTags Java.Throws
instance ToTags Java.True
instance ToTags Java.TryStatement
instance ToTags Java.TryWithResourcesStatement
instance ToTags Java.Type
instance ToTags Java.TypeArguments
instance ToTags Java.TypeBound
instance ToTags Java.TypeIdentifier
instance ToTags Java.TypeParameter
instance ToTags Java.TypeParameters
instance ToTags Java.UnannotatedType
instance ToTags Java.UnaryExpression
instance ToTags Java.UpdateExpression
instance ToTags Java.VariableDeclarator
instance ToTags Java.VoidType
instance ToTags Java.WhileStatement
instance ToTags Java.Wildcard
