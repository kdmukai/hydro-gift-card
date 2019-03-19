# HydroGiftCard

Implements the requirements outlined in [create a Gift Card Ethereum Smart Contract](https://github.com/HydroBlockchain/hcdp/issues/253) leveraging the Hydro ecosystem.

## Overview
`HydroGiftCard` is implemented as a Snowflake Resolver which uses the Resolver's allowance system to facilitate easier HYDRO token exchanges. The customer must deposit HYDRO into their snowflake and would then add `HydroGiftCard` as a resolver for their snowflake and allocate a sufficient allowance which they'll use to purchase `GiftCards`.

Vendors will specify `Offers` consisting of the gift card denominations that will be available to purchase (e.g. 100,000 HYDRO, 50,000 HYDRO, etc.). Vendors must have an identity registered in the Hydro ecosystem as their `Offers` are tied to their EIN.

Customers may buy a vendor's `Offer` for the exact amount of HYDRO which will be deducted from the `HydroGiftCard` resolver's allowance. The resulting `GiftCard` is tied to the customer's EIN and the vendor's EIN in a simple struct:

```solidity
struct GiftCard {
  uint id;          // unique GiftCard identifier
  uint vendor;      // vendor's EIN
  uint customer;    // customer's/recipient's EIN
  uint balance;     // amount of HYDRO remaining
  uint vendorRedeemAllowed;   // amount authorized for the vendor to transfer
}
```
_note: the current implementation does not include an expiration date as gift cards are forbidden from expiring in California._

The funds are held in escrow in the `HydroGiftCard` smart contract until they are either redeemed or refunded.

The typical use case would have the customer then gift the `GiftCard` to another user. The recipient must have an identity and upon transfer would be entered as the new `GiftCard.customer` EIN. This transfer can only be authorized by the current `GiftCard.customer` via a signed permission statement from the customer's ClientRaindrop address.

The recipient can then redeem the `GiftCard` by spending it at the vendor. Redemption also requires a signed permission statement from the recipient's ClientRaindrop address. The authorized funds can only be transferred to the vendor.

The vendor's side of redeeming a `GiftCard` is demonstrated in the `VendorSampleContract`. Its `receiveRedeemApproval()` function is analagous to an ERC20's `receiveApproval()`. It allows the vendor's smart contract to trigger the funds transfer and then complete whatever business logic it needs to attend to.

A basic refund mechanism allows vendors to close out their `GiftCards` and transfer the remaining HYDRO balance out of escrow and back to the customer.

## Testing With Truffle
- This folder has a suite of tests created through [Truffle](https://github.com/trufflesuite/truffle).
- To run these tests:
  - Clone this repo: `git clone https://github.com/kdmukai/hydro-gift-card.git`
  - Run `npm install`
  - Build dependencies with `npm run build`
  - Spin up a development blockchain: `npm run chain`
  - In another terminal tab, run the test suite: `npm test`
