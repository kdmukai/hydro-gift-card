pragma solidity ^0.5.0;

import "./SignatureVerifier.sol";
import "./zeppelin/ownership/Ownable.sol";
import "./zeppelin/math/SafeMath.sol";

import "./interfaces/ClientRaindropInterface.sol";
import "./interfaces/HydroInterface.sol";
import "./interfaces/IdentityRegistryInterface.sol";
import "./interfaces/SnowflakeInterface.sol";

contract HydroGiftCard is Ownable, SignatureVerifier {
    using SafeMath for uint;

    // SC variables
    address public identityRegistryAddress;
    IdentityRegistryInterface private identityRegistry;
    address public hydroTokenAddress;
    HydroInterface private hydroToken;
    address public clientRaindropAddress;
    ClientRaindropInterface private clientRaindrop;
    address public snowflakeAddress;

    struct Offer {
      uint[] amounts;   // Available gift card denominations
    }
    // Mapping from Hydro EIN to Offer
    mapping (uint => Offer) private offers;

    struct GiftCard {
      uint id;
      uint vendor;
      uint customer;
      uint balance;
    }
    // Mapping of customer's EIN to array of GiftCard IDs
    mapping(uint => uint[]) private customerGiftCardIds;

    // Mapping of vendor's EIN to array of GiftCard IDs
    mapping(uint => uint[]) private vendorGiftCardIds;

    mapping(uint => GiftCard) private giftCardsById;

    uint maxCardId;

    constructor (address _identityRegistryAddress, address _hydroTokenAddress, address _snowflakeAddress, address _clientRaindropAddress) public {
        setAddresses(_identityRegistryAddress, _hydroTokenAddress, _snowflakeAddress, _clientRaindropAddress);
        maxCardId = 1000;
    }

    // set the hydro token and identity registry addresses
    function setAddresses(address _identityRegistryAddress, address _hydroTokenAddress, address _snowflakeAddress, address _clientRaindropAddress) public onlyOwner {
        identityRegistryAddress = _identityRegistryAddress;
        identityRegistry = IdentityRegistryInterface(identityRegistryAddress);

        hydroTokenAddress = _hydroTokenAddress;
        hydroToken = HydroInterface(hydroTokenAddress);

        clientRaindropAddress = _clientRaindropAddress;
        clientRaindrop = ClientRaindropInterface(clientRaindropAddress);

        snowflakeAddress = _snowflakeAddress;
    }

    function helloWorld() public pure returns (string memory) {
      string memory greeting = "Hello, World";
      return greeting;
    }

    /***************************************************************************
    *   Vendor functions
    ***************************************************************************/
    function setOffer(uint[] memory _amounts) public {
      uint _vendorEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      offers[_vendorEIN] = Offer(_amounts);
      emit HydroGiftCardOffersSet(_vendorEIN, _amounts);
    }

    function refundGiftCard(uint _id) public {
      /** Refund HYDRO to customer's Snowflake **/
      GiftCard storage _giftCard = giftCardsById[_id];
      if (_giftCard.balance == 0) {
        // Nothing to do
        return;
      }
      uint _amountToRefund = _giftCard.balance;
      _giftCard.balance = 0;
      hydroToken.approveAndCall(snowflakeAddress, _amountToRefund, abi.encode(_giftCard.customer));
      emit HydroGiftCardRefunded(_giftCard.id, _giftCard.vendor, _giftCard.customer, _amountToRefund);
    }

    function refundAllGiftCards() public {
      /** Refund HYDRO to customer's Snowflake for all GiftCards for vendor **/
      uint _vendorEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      uint[] memory _ids = vendorGiftCardIds[_vendorEIN];
      for (uint i=0; i<_ids.length; i++) {
        refundGiftCard(_ids[i]);
      }
    }

    function getOffer(uint _vendorEIN) public view returns (uint[] memory) {
      return offers[_vendorEIN].amounts;
    }

    function receiveApproval(address _sender, uint _value, address _tokenAddress, bytes memory _bytes) public {
      /**
        Called by the HYDRO contract's approveAndCall function.
      **/
      emit Debug("receiveApproval");

      // only accept calls from HYDRO
      require(_tokenAddress == hydroTokenAddress, "_tokenAddress did not match hydroTokenAddress");

      // Parse the vendor's EIN from the passed in _bytes data
      uint _vendorEIN = abi.decode(_bytes, (uint));
      require(identityRegistry.identityExists(_vendorEIN), "The recipient EIN does not exist.");
      emit Debug(_vendorEIN);

      uint _buyerEIN = identityRegistry.getEIN(_sender);   // throws error if address not associated with an EIN

      // Does this vendor have any offers?
      require(offers[_vendorEIN].amounts.length != 0, "Vendor has no available offers");

      // Does the vendor offer this amount in a gift card?
      // TODO:

      // Transfer the HYDRO funds into the contract first...
      require(hydroToken.transferFrom(_sender, address(this), _value), "Transfer failed");

      // ...then add to the ledger
      maxCardId += 1;
      GiftCard memory gc = GiftCard(maxCardId, _vendorEIN, _buyerEIN, _value);
      customerGiftCardIds[_buyerEIN].push(gc.id);
      vendorGiftCardIds[_vendorEIN].push(gc.id);
      giftCardsById[maxCardId] = gc;

      // Announce GiftCard purchased Event
      emit HydroGiftCardPurchased(_vendorEIN, _buyerEIN, _value);
    }

    function transferGiftCard(
        uint _giftCardId, uint _recipientEIN,
        uint8 v, bytes32 r, bytes32 s
    ) public {
      // GiftCard must exist
      require(giftCardsById[_giftCardId].id != 0);
      uint _buyerEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      GiftCard storage _giftCard = giftCardsById[_giftCardId];
      require(_giftCard.customer == _buyerEIN, "You don't have permission to transfer this gift card");
      require(_giftCard.balance > 0, "Can't transfer an empty gift card!");

      // Transfer must be signed by the customer
      require(
          isSigned(
              msg.sender,
              keccak256(
                  abi.encodePacked(
                      byte(0x19), byte(0), address(this),
                      "I authorize the transfer of this gift card.",
                      _giftCard.id, _recipientEIN
                  )
              ),
              v, r, s
          ),
          "Permission denied."
      );

      // Apply changes
      _giftCard.customer = _recipientEIN;
      emit HydroGiftCardTransferred(_giftCardId, _buyerEIN, _recipientEIN);
    }

    function transferGiftCard(
        uint _giftCardId, string memory _recipientHydroID,
        uint8 v, bytes32 r, bytes32 s
    ) public {
      /** Convenience version via hydroID **/
      (uint _recipientEIN, address _address, string memory _casedHydroID) = clientRaindrop.getDetails(_recipientHydroID);
      transferGiftCard(_giftCardId, _recipientEIN, v, r, s);
    }

    function getGiftCardBalance(uint _giftCardId) public view returns (uint) {
      return giftCardsById[_giftCardId].balance;
    }

    function getGiftCard(uint _id) public view returns(string memory vendorCasedHydroID, uint balance) {
      GiftCard memory _giftCard = giftCardsById[_id];

      (address _address, string memory _vendorCasedHydroID) = clientRaindrop.getDetails(_giftCard.vendor);
      return (_vendorCasedHydroID, _giftCard.balance);
    }

    function getCustomerGiftCardIds() public view returns(uint[] memory giftCardIds) {
      uint _buyerEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      return customerGiftCardIds[_buyerEIN];
    }

    event Debug(string);
    event Debug(uint);

    event HydroGiftCardOffersSet(uint indexed _vendorEIN, uint[] _amounts);
    event HydroGiftCardPurchased(uint indexed _vendorEIN, uint indexed _buyerEIN, uint _amount);
    event HydroGiftCardRefunded(uint indexed _id, uint indexed _vendorEIN, uint indexed _customerEIN, uint _amount);
    event HydroGiftCardTransferred(uint indexed _id, uint indexed _buyerEIN, uint indexed _recipientEIN);
}
