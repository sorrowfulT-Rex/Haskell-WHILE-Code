{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SimpleExp where

import qualified Data.Map as M
import Control.Monad.Trans.Class
import Control.Monad.Trans.State
import Expression ( Expression(..) )
import Definitions
import Text.Parsec hiding (State)
import Text.Parsec.String
import Text.Parsec.Expr
import Text.Parsec.Token
import Text.Parsec.Language
import Utilities ( eatBlankSpace, int )
import Control.Monad

instance Expression SimpleExp where
  -- | Is normal (irreducible).
  {-# INLINE isNormal #-}
  isNormal :: SimpleExp -> Bool
  isNormal EVal {} = True
  isNormal _       = False

  -- | Big-Step evaluation.
  evalS :: SimpleExp -> StateT Context Maybe SimpleExp
  evalS e = do
    c <- get
    let binOp op e e' fromValMaybe toVal = do
          l <- evalS e >>= lift . fromValMaybe . val
          r <- evalS e' >>= lift . fromValMaybe . val
          return $ EVal $ toVal $ l `op` r
    let unOp op e fromValMaybe toVal
          = EVal . toVal . op <$> (evalS e >>= lift . fromValMaybe . val)
    case e of
      EVal v    -> return $ EVal v
      EVar v    -> EVal <$> lift (M.lookup v c)
      Plus e e' -> binOp (+)  e e' fromNumMaybe VNum
      Mnus e e' -> binOp (-)  e e' fromNumMaybe VNum
      Prod e e' -> binOp (*)  e e' fromNumMaybe VNum
      ELT e e'  -> binOp (<)  e e' fromNumMaybe VBool
      EGT e e'  -> binOp (>)  e e' fromNumMaybe VBool
      ELE e e'  -> binOp (<=) e e' fromNumMaybe VBool
      EGE e e'  -> binOp (>=) e e' fromNumMaybe VBool
      EEQ e e'  -> do
        let numArgs  = evalStateT (binOp (==) e e' fromNumMaybe VBool) c
        let boolArgs = evalStateT (binOp (==) e e' fromBoolMaybe VBool) c
        lift $ numArgs `mplus` boolArgs
      ENE e e'  -> do
        let numArgs  = evalStateT (binOp (==) e e' fromNumMaybe VBool) c
        let boolArgs = evalStateT (binOp (==) e e' fromBoolMaybe VBool) c
        lift $ numArgs `mplus` boolArgs
      And e e'  -> binOp (&&) e e' fromBoolMaybe VBool
      Or  e e'  -> binOp (&&) e e' fromBoolMaybe VBool
      Not e     -> unOp  not  e    fromBoolMaybe VBool

  -- | Small-Step evaluation. Encoded with Nothing if either in normal form or
  -- stuck state.
  eval1S :: SimpleExp -> StateT Context Maybe SimpleExp
  eval1S e = do
    let binOp op e e' fromValMaybe toVal toExp = case (e, e') of
          (EVal l, EVal r) -> do
            lv <- lift $ fromValMaybe l
            rv <- lift $ fromValMaybe r
            return $ EVal $ toVal $ lv `op` rv
          (EVal l, e')     -> toExp e <$> eval1S e'
          (e,      e')     -> flip toExp e' <$> eval1S e
    let unOp op e fromValMaybe toVal toExp = case e of
          (EVal v) -> EVal . toVal . op <$> lift (fromValMaybe v)
          e        -> toExp <$> eval1S e 
    c <- get
    case e of
      Plus e e' -> binOp (+)  e e' fromNumMaybe  VNum  Plus
      Mnus e e' -> binOp (-)  e e' fromNumMaybe  VNum  Mnus
      Prod e e' -> binOp (*)  e e' fromNumMaybe  VNum  Prod
      ELT e e'  -> binOp (<)  e e' fromNumMaybe  VBool ELT
      EGT e e'  -> binOp (>)  e e' fromNumMaybe  VBool EGT
      ELE e e'  -> binOp (<=) e e' fromNumMaybe  VBool ELE
      EGE e e'  -> binOp (>=) e e' fromNumMaybe  VBool EGE
      ENE e e'  -> do
        let numArgs  = evalStateT (binOp (/=) e e' fromNumMaybe VBool ENE) c
        let boolArgs = evalStateT (binOp (/=) e e' fromBoolMaybe VBool ENE) c
        lift $ numArgs `mplus` boolArgs
      EEQ e e'  -> do
        let numArgs  = evalStateT (binOp (==) e e' fromNumMaybe VBool EEQ) c
        let boolArgs = evalStateT (binOp (==) e e' fromBoolMaybe VBool EEQ) c
        lift $ numArgs `mplus` boolArgs
      -- BASE RULES:
      EVar v -> do
        EVal <$> lift (M.lookup v c)
      EVal _ -> lift Nothing
      And e e'  -> binOp (&&) e e' fromBoolMaybe VBool And
      Or  e e'  -> binOp (&&) e e' fromBoolMaybe VBool Or
      Not e     -> unOp  not  e    fromBoolMaybe VBool Not

-- | The parser for SimpleExp
expParser :: Parser SimpleExp
expParser = eatBlankSpace >> parser' <* eof
  where
    parser' = buildExpressionParser expTable expTerm <?> "Expression"
    TokenParser
      { parens = expParens
      , identifier = expIdentifier
      , reservedOp = expReservedOp
      , reserved = expReserved
      } = makeTokenParser $ emptyDef
          { identStart = letter
          , identLetter = alphaNum
          , caseSensitive = True
          , opStart = oneOf ""
          , opLetter = oneOf ""
          , reservedOpNames
              = ["+", "-", "*", "<=", ">=", "==", "!=", "<", ">", "&", "|", "!"]
          , reservedNames = ["true", "false"]
          }
    expTerm
        = expParens parser'
      <|> EVar <$> expIdentifier
      <|> EVal . VNum <$> int
      <|> EVal <$> (expReserved "true" >> return (VBool True))
      <|> EVal <$> (expReserved "false" >> return (VBool False))
    expTable =
      [ [ Prefix (expReservedOp "!" >> return Not) ]
      , [ Infix (expReservedOp "*" >> return Prod) AssocLeft ]
      , [ Infix (expReservedOp "+" >> return Plus) AssocLeft
        , Infix (expReservedOp "-" >> return Mnus) AssocLeft
        ]
      , [ Infix (expReservedOp "<=" >> return ELE) AssocLeft
        , Infix (expReservedOp ">=" >> return EGE) AssocLeft
        , Infix (expReservedOp "<"  >> return ELT) AssocLeft
        , Infix (expReservedOp ">"  >> return EGT) AssocLeft
        ]
      , [ Infix (expReservedOp "!=" >> return ENE) AssocLeft
        , Infix (expReservedOp "==" >> return EEQ) AssocLeft
        , Infix (expReservedOp "="  >> return EEQ) AssocLeft
        ]
      , [ Infix  (expReservedOp "&" >> return And) AssocLeft ]
      , [ Infix  (expReservedOp "|" >> return Or)  AssocLeft ]
      ]
