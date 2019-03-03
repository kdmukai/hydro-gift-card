pragma solidity 0.5.0;

import "../interfaces/ClientRaindropInterface.sol";
import "../zeppelin/ownership/Ownable.sol";

interface HydroGiftCardInterface {
  function vendorRedeem(uint _giftCardId, uint _amount) external;
  function getGiftCard(uint _id) external view returns(
      string memory vendorCasedHydroID,
      string memory customerCasedHydroID,
      uint balance
  );
}

contract VendorSampleContract is Ownable {
  address public clientRaindropAddress;
  ClientRaindropInterface private clientRaindrop;

  function setAddresses(address _clientRaindropAddress) public onlyOwner {
      clientRaindropAddress = _clientRaindropAddress;
      clientRaindrop = ClientRaindropInterface(clientRaindropAddress);
  }

  function receiveRedeemApproval(
    uint _giftCardId, uint256 _value,
    address _giftCardContract, bytes memory _extraData
  ) public {
    /*************************************************************************************
      Called by the HydroGiftCard contract's redeemAndCall(). The customer has authorized
      the GiftCard to payout _value to the receiving vendor. Receive the transfer and
      continue handling whatever remains for the customer's transaction. Vendor's smart
      contract must be associated with their vendorEIN for the transfer to be executed.
    *************************************************************************************/

    // Instantiate the HydroGiftCard contract interface and get GiftCard details
    HydroGiftCardInterface hydroGiftCard = HydroGiftCardInterface(_giftCardContract);
    (string memory vendorCasedHydroID, string memory customerCasedHydroID, uint balance) = hydroGiftCard.getGiftCard(_giftCardId);

    // Get the customer's EIN via ClientRaindrop
    (uint customerEIN, address customerAddress, string memory _customerCasedHydroID) = clientRaindrop.getDetails(customerCasedHydroID);

    // Tell the HydroGiftCard to transfer the HYDRO funds
    hydroGiftCard.vendorRedeem(_giftCardId, _value);

    // Decode params were passed into redeemAndCall())
    uint invoiceId = abi.decode(_extraData, (uint));

    // ...credit customerEIN for invoiceId...

    emit InvoicePaid(invoiceId, _value);
  }

  event InvoicePaid(uint _invoiceId, uint _amount);
}
