{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}

-- | Transaction processing logic.

module Pos.Txp.Logic
       (
         txVerifyBlocks
       , txApplyBlocks
       , processTx
       , txRollbackBlocks
       ) where

import           Control.Lens            (each, over, view, (^.), _1, _3)
import qualified Data.HashMap.Strict     as HM
import qualified Data.HashSet            as HS
import           Data.List.NonEmpty      (NonEmpty)
import qualified Data.List.NonEmpty      as NE
import           Formatting              (sformat, stext, (%))
import           System.Wlog             (WithLogger)
import           Universum

import           Pos.Constants           (maxLocalTxs)
import           Pos.Crypto              (WithHash (..), hash, withHash)
import           Pos.DB                  (DB, MonadDB, getUtxoDB)
import           Pos.DB.Utxo             (BatchOp (..), getTip, writeBatchToUtxo)
import           Pos.Ssc.Class.Types     (Ssc)
import           Pos.State.Storage.Types (AltChain)
import           Pos.Txp.Class           (MonadTxpLD (..), TxpLD, getUtxoView)
import           Pos.Txp.Error           (TxpError (..))
import           Pos.Txp.Holder          (TxpLDHolder, runLocalTxpLDHolder)
import           Pos.Txp.Types           (MemPool (..), UtxoView (..))
import           Pos.Txp.Types.Types     (ProcessTxRes (..), mkPTRinvalid)
import qualified Pos.Txp.Types.UtxoView  as UV
import           Pos.Types               (Block, MonadUtxo, MonadUtxoRead (utxoGet),
                                          SlotId, Tx (..), TxAux, TxDistribution (..),
                                          TxId, TxIn (..), TxOutAux, TxWitness, Undo,
                                          VTxGlobalContext (..), VTxLocalContext (..),
                                          applyTxToUtxo', blockSlot, blockTxas,
                                          headerHash, prevBlockL, slotIdF, topsortTxs,
                                          verifyTxPure)
import           Pos.Types.Utxo          (verifyAndApplyTxs, verifyTxUtxo)
import           Pos.Util                (inAssertMode, _neHead)

type TxpWorkMode ssc m = ( Ssc ssc
                         , WithLogger m
                         , MonadDB ssc m
                         , MonadTxpLD ssc m
                         , MonadUtxo m
                         , MonadThrow m)

type MinTxpWorkMode ssc m = ( MonadDB ssc m
                            , MonadTxpLD ssc m
                            , MonadUtxo m
                            , MonadThrow m)

-- | Apply chain of /definitely/ valid blocks to state on transactions
-- processing.
txApplyBlocks :: TxpWorkMode ssc m => AltChain ssc -> m ()
txApplyBlocks blocks = do
    tip <- getTip
    when (tip /= blocks ^. _neHead . prevBlockL) $ throwM $
        TxpCantApplyBlocks "oldest block in AltChain is not based on tip"
    inAssertMode $
        do verdict <- txVerifyBlocks blocks
           case verdict of
               Right _ -> pass
               Left errors ->
                   panic $ "txVerifyBlocks failed: " <> errors
    -- Apply all the blocks' transactions
    -- TODO actually, we can improve it: we can use UtxoView from txVerifyBlocks
    -- Now we recalculate TxIn which must be removed from Utxo DB or added to Utxo DB
    -- I can improve it, if it is bottlneck
    -- We apply all blocks and filter mempool for every block
    mapM_ txApplyBlock $ NE.toList blocks
    normalizeTxpLD

txApplyBlock
    :: TxpWorkMode ssc m
    => Block ssc -> m ()
txApplyBlock blk = do
    let hashPrevHeader = blk ^. prevBlockL
    tip <- getTip
    when (tip /= hashPrevHeader) $
        panic
            "disaster, tip mismatch in txApplyBlock, probably semaphore doesn't work"
    let batch = foldr' prependToBatch [] txsAndIds
    filterMemPool txsAndIds
    writeBatchToUtxo (PutTip (headerHash blk) : batch)
  where
    txas = either (const []) (toList . view blockTxas) blk
    txsAndIds = map (\tx -> (hash (tx ^. _1), (tx ^. _1, tx ^. _3))) txas
    prependToBatch :: (TxId, (Tx, TxDistribution))
                   -> [BatchOp ssc] -> [BatchOp ssc]
    prependToBatch (txId, (Tx{..}, distr)) batch =
        let keys = zipWith TxIn (repeat txId) [0 ..]
            delIn = map DelTxIn txInputs
            putOut = zipWith AddTxOut
                         keys
                         (zip txOutputs (getTxDistribution distr))
        in foldr' (:) (foldr' (:) batch putOut) delIn --how we could simplify it?

-- | Verify whether sequence of blocks can be applied to current Tx
-- state.  This function doesn't make pure checks for transactions,
-- they are assumed to be done earlier.
txVerifyBlocks
    :: forall ssc m.
       MonadDB ssc m
    => AltChain ssc -> m (Either Text (NonEmpty Undo))
txVerifyBlocks newChain = do
    utxoDB <- getUtxoDB
    fmap (NE.fromList . reverse) <$>
      runLocalTxpLDHolder
        (foldM verifyDo (Right []) newChainTxs)
        (UV.createFromDB utxoDB)
  where
    newChainTxs :: [(SlotId, [(WithHash Tx, TxWitness, TxDistribution)])]
    newChainTxs =
        map (\b -> (b ^. blockSlot, over (each . _1) withHash (b ^. blockTxas))) $
        rights (NE.toList newChain)
    verifyDo
        :: Either Text [Undo]
        -> (SlotId, [(WithHash Tx, TxWitness, TxDistribution)])
        -> TxpLDHolder ssc m (Either Text [Undo])
    verifyDo failure@(Left _) _ = pure failure
    verifyDo undos (slotId, txws) =
        attachSlotId slotId <$>
        (liftA2 (flip (:)) undos) <$>
        verifyAndApplyTxs False txws
    attachSlotId _ suc@(Right _) = suc
    attachSlotId sId (Left errors) =
        Left $ (sformat ("[Block's slot = "%slotIdF % "]"%stext) sId) errors

-- CHECK: @processTx
-- #processTxDo
processTx :: MinTxpWorkMode ssc m => (TxId, TxAux) -> m ProcessTxRes
processTx itw@(_, (tx, _, _)) = do
    tipBefore <- getTip
    resolved <-
      foldM (\s inp -> maybe s (\x -> HM.insert inp x s) <$> utxoGet inp)
            mempty (txInputs tx)
    db <- getUtxoDB
    modifyTxpLD (\txld@(_, mp, _, tip) ->
        let localSize = localTxsSize mp in
        if tipBefore == tip then
            if localSize < maxLocalTxs
                then processTxDo txld resolved db itw
                else (PTRoverwhelmed, txld)
        else
            (mkPTRinvalid ["Tips aren't same"], txld)
        )

-- CHECK: @processTxDo
-- #verifyTxPure
processTxDo :: TxpLD ssc -> HM.HashMap TxIn TxOutAux -> DB ssc
            -> (TxId, TxAux) -> (ProcessTxRes, TxpLD ssc)
processTxDo ld@(uv, mp, undos, tip) resolvedIns utxoDB (id, (tx, txw, txd))
    | HM.member id locTxs = (PTRknown, ld)
    | otherwise =
        case verifyRes of
            Right _     -> newState addUtxo' delUtxo' locTxs locTxsSize undos
            Left errors -> (PTRinvalid errors, ld)
  where
    verifyRes =
        verifyTxPure True VTxGlobalContext inputResolver (tx, txw, txd)
    locTxs = localTxs mp
    locTxsSize = localTxsSize mp
    addUtxo' = addUtxo uv
    delUtxo' = delUtxo uv
    inputResolver tin
        | HS.member tin delUtxo' = Nothing
        | otherwise =
            VTxLocalContext <$>
            maybe (HM.lookup tin addUtxo') Just (HM.lookup tin resolvedIns)
    prependToUndo undo inp =
        fromMaybe (panic "Input not resolved")
                  (HM.lookup inp resolvedIns) : undo
    newState nAddUtxo nDelUtxo oldTxs oldSize oldUndos =
        let keys = zipWith TxIn (repeat id) [0 ..]
            zipKeys = zip keys (txOutputs tx `zip` getTxDistribution txd)
            newAddUtxo' = foldl' (flip $ uncurry HM.insert) nAddUtxo zipKeys
            newDelUtxo' = foldl' (flip HS.insert) nDelUtxo (txInputs tx)
            newUndos = HM.insert id (reverse $ foldl' prependToUndo [] (txInputs tx)) oldUndos
        in ( PTRadded
           , ( UtxoView newAddUtxo' newDelUtxo' utxoDB
             , MemPool (HM.insert id (tx, txw, txd) oldTxs) (oldSize + 1)
             , newUndos
             , tip))

-- | Head of list is the youngest block
txRollbackBlocks :: (WithLogger m, MonadDB ssc m)
                 => NonEmpty (Block ssc, Undo) -> m ()
txRollbackBlocks = mapM_ txRollbackBlock

-- | Rollback block
txRollbackBlock :: (WithLogger m, MonadDB ssc m)
                => (Block ssc, Undo) -> m ()
txRollbackBlock (block, undo) = do
    let txs = getTxs block
    --TODO more detailed message must be here
    unless (length undo == length txs)
        $ panic "Number of txs must be equal length of undo"
    let batchOrError = foldl' prependToBatch (Right []) $ zip txs undo
    case batchOrError of
        Left msg    -> panic msg
        Right batch -> writeBatchToUtxo $ PutTip (block ^. prevBlockL) : batch
        -- If we store block cache in UtxoView we must invalidate it
  where
    getTxs (Left _)   = []
    getTxs (Right mb) = map (^. _1) $ mb ^. blockTxas

    prependToBatch :: Either Text [BatchOp ssc] -> (Tx, [TxOutAux]) -> Either Text [BatchOp ssc]
    prependToBatch batchOrError (tx@Tx{..}, undoTx) = do
        batch <- batchOrError
        --TODO more detailed message must be here
        unless (length undoTx == length txInputs) $ Left "Number of txInputs must be equal length of undo"
        let txId = hash tx
            keys = zipWith TxIn (repeat txId) [0..]
            putIn = map (uncurry AddTxOut) $ zip txInputs undoTx
            delOut = map DelTxIn $ take (length txOutputs) keys
        return $ foldr' (:) (foldr' (:) batch putIn) delOut --how we could simplify it?

-- | Remove from mem pool transactions from block
filterMemPool :: MonadTxpLD ssc m => [(TxId, (Tx, TxDistribution))]  -> m ()
filterMemPool txs = modifyTxpLD_ (\(uv, mp, undos, tip) ->
    let blkTxs = HM.fromList txs
        newMPTxs = (localTxs mp) `HM.difference` blkTxs
        newUndos = undos `HM.difference` blkTxs in
    (uv, MemPool newMPTxs (HM.size newMPTxs), newUndos, tip))

-- | 1. Recompute UtxoView by current MemPool
-- | 2. Removed from MemPool invalid transactions
normalizeTxpLD :: (MonadDB ssc m, MonadTxpLD ssc m)
               => m ()
normalizeTxpLD = do
    utxoTip <- getTip
    (_, memPool, undos, _) <- getTxpLD
    let mpTxs = HM.toList . localTxs $ memPool
    emptyUtxoView <- UV.createFromDB <$> getUtxoDB
    let emptyMemPool = MemPool mempty 0
    maybe
        (setTxpLD (emptyUtxoView, emptyMemPool, mempty, utxoTip))
        (\topsorted -> do
             -- we run this code in temporary TxpLDHolder
             (validTxs, newUtxoView) <-
                 runLocalTxpLDHolder (findValid topsorted) emptyUtxoView
             setTxpLD $ newState newUtxoView validTxs undos utxoTip)
        (topsortTxs (\(i, (t, _, _)) -> WithHash t i) mpTxs)
  where
    findValid topsorted = do
        validTxs' <- foldlM canApply [] topsorted
        newUtxoView' <- getUtxoView
        return (validTxs', newUtxoView')
    newState newUtxoView validTxs undos utxoTip =
        let newTxs = HM.fromList validTxs in
        (newUtxoView, MemPool newTxs (length validTxs), undos, utxoTip)
    canApply xs itxa@(_, txa) = do
        -- Pure checks are not done here, because they are done
        -- earlier, when we accept transaction.
        verifyRes <- verifyTxUtxo False txa
        case verifyRes of
            Right _ -> do
                applyTxToUtxo' itxa
                return (itxa : xs)
            Left _ -> return xs
