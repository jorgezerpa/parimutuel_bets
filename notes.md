## Audit areas of concern
- ClaimWinnings function -> already claimed require -> is it possible that this reverts even if the user still have funds on the match? -> @INVARIANT If this is true, then user has already claimed all -> so claim should send ALL user money

## For a first flight:
- Do not consider the edge case -> Noone bets on outcome -> lock funds
- Loss of funds due to rounding to 0
- claimWinnings do not checks hasClaimed 

## INVARIANTS
- Winners claimed amount should always be bigger than their initial bet  