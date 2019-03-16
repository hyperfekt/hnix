{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import qualified Control.DeepSeq as Deep
import qualified Control.Exception as Exc
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Ref
import           Control.Monad.Trans.Class
-- import           Control.Monad.ST
import qualified Data.Aeson.Text as A
import qualified Data.HashMap.Lazy as M
import qualified Data.Map as Map
import           Data.List (sortOn)
import           Data.Maybe (fromJust)
import           Data.Time
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Data.Text.Lazy.IO as TL
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Render.Text
import           Nix
import           Nix.Cited
import           Nix.Convert
import qualified Nix.Eval as Eval
import           Nix.Fresh
import           Nix.Json
-- import           Nix.Lint
import           Nix.Options.Parser
import           Nix.Thunk.Basic
import           Nix.Thunk.Standard
import qualified Nix.Type.Env as Env
import qualified Nix.Type.Infer as HM
import           Nix.Utils
import           Nix.Var
import           Options.Applicative hiding (ParserResult(..))
import qualified Repl
import           System.FilePath
import           System.IO
import qualified Text.Show.Pretty as PS

main :: IO ()
main = do
    time <- liftIO getCurrentTime
    opts <- execParser (nixOptionsInfo time)
    runStdLazyM opts $ case readFrom opts of
        Just path -> do
            let file = addExtension (dropExtension path) "nixc"
            process opts (Just file) =<< liftIO (readCache path)
        Nothing -> case expression opts of
            Just s -> handleResult opts Nothing (parseNixTextLoc s)
            Nothing  -> case fromFile opts of
                Just "-" ->
                    liftIO $ mapM_ (processFile opts)
                        =<< (lines <$> getContents)
                Just path ->
                    liftIO $ mapM_ (processFile opts)
                        =<< (lines <$> readFile path)
                Nothing -> case filePaths opts of
                    [] -> withNixContext Nothing $ Repl.main
                    ["-"] ->
                        handleResult opts Nothing . parseNixTextLoc
                            =<< liftIO Text.getContents
                    paths ->
                        liftIO $ mapM_ (processFile opts) paths
  where
    processFile opts path = do
        eres <- parseNixFileLoc path
        handleResult opts (Just path) eres

    handleResult opts mpath = \case
        Failure err ->
            (if ignoreErrors opts
             then liftIO . hPutStrLn stderr
             else errorWithoutStackTrace) $ "Parse failed: " ++ show err

        Success expr -> do
            when (check opts) $ do
                expr' <- liftIO (reduceExpr mpath expr)
                case HM.inferTop Env.empty [("it", stripAnnotation expr')] of
                    Left err ->
                        errorWithoutStackTrace $ "Type error: " ++ PS.ppShow err
                    Right ty ->
                        liftIO $ putStrLn $ "Type of expression: "
                            ++ PS.ppShow (fromJust (Map.lookup "it" (Env.types ty)))

                -- liftIO $ putStrLn $ runST $
                --     runLintM opts . renderSymbolic =<< lint opts expr

            catch (process opts mpath expr) $ \case
                NixException frames ->
                    errorWithoutStackTrace . show
                        =<< renderFrames frames

            when (repl opts) $
                withNixContext Nothing $ Repl.main

    process opts mpath expr
        | evaluate opts, tracing opts =
              evaluateExpression mpath
                  Nix.nixTracingEvalExprLoc printer expr

        | evaluate opts, Just path <- reduce opts =
              evaluateExpression mpath (reduction path) printer expr

        | evaluate opts, not (null (arg opts) && null (argstr opts)) =
              evaluateExpression mpath
                  Nix.nixEvalExprLoc printer expr

        | evaluate opts =
              processResult printer =<< Nix.nixEvalExprLoc mpath expr

        | xml opts =
              error "Rendering expression trees to XML is not yet implemented"

        | json opts =
              liftIO $ TL.putStrLn $
                  A.encodeToLazyText (stripAnnotation expr)

        | verbose opts >= DebugInfo =
              liftIO $ putStr $ PS.ppShow $ stripAnnotation expr

        | cache opts, Just path <- mpath =
              liftIO $ writeCache (addExtension (dropExtension path) "nixc") expr

        | parseOnly opts =
              void $ liftIO $ Exc.evaluate $ Deep.force expr

        | otherwise =
              liftIO $ renderIO stdout
                  . layoutPretty (LayoutOptions $ AvailablePerLine 80 0.4)
                  . prettyNix
                  . stripAnnotation $ expr
      where
        printer
            :: forall e t f m.
            ( MonadNix e t f m
            , MonadRef m
            , MonadFreshId Int m
            , MonadVar m
            , MonadIO m
            , Typeable m
            )
            => NValue t f m -> m ()
        printer
            | finder opts =
              fromValue @(AttrSet (StdThunk m)) >=> findAttrs
            | xml opts =
              liftIO . putStrLn
                     . Text.unpack
                     . principledStringIgnoreContext
                     . toXML
                     <=< normalForm
            | json opts =
              liftIO . Text.putStrLn
                     . principledStringIgnoreContext
                     <=< nvalueToJSONNixString
            | strict opts =
              liftIO . print . prettyNValueNF <=< normalForm
            | values opts  =
              liftIO . print <=< prettyNValueProv
            | otherwise  =
              liftIO . print <=< prettyNValue
          where
            findAttrs = go ""
              where
                go prefix s = do
                    xs <- forM (sortOn fst (M.toList s))
                        $ \(k, nv@(StdThunk (NCited _ t))) -> case t of
                            Value v -> pure (k, Just v)
                            Thunk _ _ ref -> do
                                let path = prefix ++ Text.unpack k
                                    (_, descend) = filterEntry path k
                                val <- readVar @m ref
                                case val of
                                    Computed _ -> pure (k, Nothing)
                                    _ | descend   -> (k,) <$> forceEntry path nv
                                      | otherwise -> pure (k, Nothing)

                    forM_ xs $ \(k, mv) -> do
                        let path = prefix ++ Text.unpack k
                            (report, descend) = filterEntry path k
                        when report $ do
                            liftIO $ putStrLn path
                            when descend $ case mv of
                                Nothing -> return ()
                                Just v -> case v of
                                    StdValue (NVSet s' _) ->
                                        go (path ++ ".") s'
                                    _ -> return ()
                  where
                    filterEntry path k = case (path, k) of
                        ("stdenv", "stdenv")           -> (True,  True)
                        (_,        "stdenv")           -> (False, False)
                        (_,        "out")              -> (True,  False)
                        (_,        "src")              -> (True,  False)
                        (_,        "mirrorsFile")      -> (True,  False)
                        (_,        "buildPhase")       -> (True,  False)
                        (_,        "builder")          -> (False,  False)
                        (_,        "drvPath")          -> (False,  False)
                        (_,        "outPath")          -> (False,  False)
                        (_,        "__impureHostDeps") -> (False,  False)
                        (_,        "__sandboxProfile") -> (False,  False)
                        ("pkgs",   "pkgs")             -> (True,  True)
                        (_,        "pkgs")             -> (False, False)
                        (_,        "drvAttrs")         -> (False, False)
                        _ -> (True, True)

                    forceEntry k v = catch (Just <$> force v pure)
                        $ \(NixException frames) -> do
                              liftIO . putStrLn
                                     . ("Exception forcing " ++)
                                     . (k ++)
                                     . (": " ++) . show
                                  =<< renderFrames @(StdThunk m) frames
                              return Nothing

    reduction path mp x = do
        eres <- Nix.withNixContext mp $
            Nix.reducingEvalExpr (Eval.eval . annotated . getCompose) mp x
        handleReduced path eres

    handleReduced :: (MonadThrow m, MonadIO m)
                  => FilePath
                  -> (NExprLoc, Either SomeException (NValue t f m))
                  -> m (NValue t f m)
    handleReduced path (expr', eres) = do
        liftIO $ do
            putStrLn $ "Wrote winnowed expression tree to " ++ path
            writeFile path $ show $ prettyNix (stripAnnotation expr')
        case eres of
            Left err -> throwM err
            Right v  -> return v
