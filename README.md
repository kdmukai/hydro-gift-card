# HydroGiftCard

Implements the requirements outlined in [create a Gift Card Ethereum Smart Contract](https://github.com/HydroBlockchain/hcdp/issues/253) leveraging the Hydro ecosystem.

## Overview
Vendors will specify `Offers` consisting of the gift card denominations that they will offer (e.g. 100,000 HYDRO, 50,000 HYDRO, etc.). Vendors must have an identity registered in the Hydro ecosystem as their `Offers` are tied to their EIN.

Customers may buy a vendor's `Offer` for the exact amount of HYDRO. Customers must also have an identity registered in the Hydro ecosystem. The resulting `GiftCard` is tied to their EIN and the vendor's EIN in a simple struct:

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

The funds are held in the `HydroGiftCard` smart contract until they are either redeemed or refunded.

The typical use case would have the customer then gift the `GiftCard` to another user. The recipient must have an EIN and upon transfer would be entered as the new `GiftCard.customer`. This transfer can only be authorized by the current `GiftCard.customer` via a signed permission statement from an address associated with the customer's EIN.

The recipient can then redeem the `GiftCard` by spending it at the vendor. Redemption also requires a signed permission statement from an address associated with the recipient's EIN. The authorized funds can only be transferred to the vendor.

The vendor's side of redeeming a `GiftCard` is demonstrated in the `VendorSampleContract`.
