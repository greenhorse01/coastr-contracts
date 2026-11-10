<p align="center"><a href="https://coastrapp.xyz"><img src=".github/banner.jpg" alt="Coastr: GPU compute, by the hour, on Robinhood Chain" width="100%"></a></p>

# Coastr contracts

Smart contract behind [Coastr](https://coastrapp.xyz), a peer-to-peer market for GPU time sold by the hour.

## CoastrSeats

One seat is one hour on one seller's GPU, minted as an ERC-721 when it is bought.

- **List:** a seller lists future hours at a price in ETH (`list`, `listMany`) and can cancel unsold ones (`cancel`).
- **Buy:** a renter pays the price, which the contract holds in escrow (`buy` for a later hour, `rentNow` for the current one).
- **Trade:** a seat can be transferred until its hour starts. After that it can only be redeemed (`redeem`).
- **Settle:** once the hour is over, the seller claims the price minus the fee (`claim`, `claimMany`). The fee goes to `feeTo` and is capped at 10% (`MAX_FEE_BPS`). Coastr runs it at 5%.
- **Refund:** the owner can refund the renter in full if an hour was not served and has not been claimed yet (`refund`).

The owner cannot move funds anywhere else: a refund always goes to the seat's holder, and the contract is not upgradeable.

## Deployment

| Network | Chain ID | Address |
|---|---|---|
| Robinhood Chain mainnet | 4663 | [`0x69aA6e0B8FD9B877184f0764A4151c27314F870b`](https://robinhoodchain.blockscout.com/address/0x69aA6e0B8FD9B877184f0764A4151c27314F870b) |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```shell
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
forge build
forge test
```

## Status

This contract has not been audited. Use small amounts.

## License

MIT
