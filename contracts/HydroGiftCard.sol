pragma solidity 0.5.0;

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
    // Mapping from vendor's EIN to Offer
    mapping (uint => Offer) private offers;

    uint maxGiftCardId;
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

    // Mapping of customer's EIN to mapping of vendor's EIN to amount redeemable
    mapping(uint => mapping(uint => uint)) private redeemAllowed;

    // signature variables
    uint public signatureTimeout = 1 days;

    // enforces signature timeouts
    modifier ensureSignatureTimeValid(uint timestamp) {
        require(
            // solium-disable-next-line security/no-block-members
            block.timestamp >= timestamp && block.timestamp < timestamp + signatureTimeout, "Timestamp is not valid."
        );
        _;
    }


    constructor (address _identityRegistryAddress, address _hydroTokenAddress, address _snowflakeAddress, address _clientRaindropAddress) public {
        setAddresses(_identityRegistryAddress, _hydroTokenAddress, _snowflakeAddress, _clientRaindropAddress);
        maxGiftCardId = 1000;
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


    /***************************************************************************
    *   Buyer functions
    ***************************************************************************/
    function receiveApproval(address _sender, uint _value, address _tokenAddress, bytes memory _bytes) public {
      /**
        Called by the HYDRO contract's approveAndCall function.
      **/
      // only accept calls from HYDRO
      require(_tokenAddress == hydroTokenAddress, "_tokenAddress did not match hydroTokenAddress");

      // Parse the vendor's EIN from the passed in _bytes data
      uint _vendorEIN = abi.decode(_bytes, (uint));
      require(identityRegistry.identityExists(_vendorEIN), "The recipient EIN does not exist.");

      uint _buyerEIN = identityRegistry.getEIN(_sender);   // throws error if address not associated with an EIN

      // Does this vendor have any offers?
      require(offers[_vendorEIN].amounts.length != 0, "Vendor has no available offers");

      // Does the vendor offer this amount in a gift card?
      // TODO:

      // Transfer the HYDRO funds into the contract first...
      require(hydroToken.transferFrom(_sender, address(this), _value), "Transfer failed");

      // ...then add to the ledger
      maxGiftCardId += 1;
      GiftCard memory gc = GiftCard(maxGiftCardId, _vendorEIN, _buyerEIN, _value);
      customerGiftCardIds[_buyerEIN].push(gc.id);
      vendorGiftCardIds[_vendorEIN].push(gc.id);
      giftCardsById[maxGiftCardId] = gc;

      // Announce GiftCard purchased Event
      emit HydroGiftCardPurchased(_vendorEIN, _buyerEIN, _value);
    }

    function transferGiftCard(
        uint _giftCardId, uint _recipientEIN,
        uint8 v, bytes32 r, bytes32 s
    ) public {
      // GiftCard must exist
      require(giftCardsById[_giftCardId].id != 0, "Invalid _giftCardId");
      uint _buyerEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      GiftCard storage _giftCard = giftCardsById[_giftCardId];

      require(_giftCard.customer == _buyerEIN, "You aren't the owner of this gift card.");
      require(_giftCard.balance > 0, "Can't transfer an empty gift card.");
      identityRegistry.getIdentity(_recipientEIN);     // throws error if unknown EIN

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

      // Remove this GiftCard from the original customer's Mapping
      uint[] storage giftCardIds = customerGiftCardIds[_buyerEIN];
      if (giftCardIds.length == 1) {
        giftCardIds.pop();
      } else {
        for (uint i=0; i<giftCardIds.length; i++) {
          if (giftCardIds[i] == _giftCardId) {
            // Copy the last id over the outgoing id...
            giftCardIds[i] = giftCardIds[giftCardIds.length - 1];

            // ...and trim the whole array
            giftCardIds.pop();
            break;
          }
        }
      }

      // Transfer the ownership in the object...
      _giftCard.customer = _recipientEIN;

      // ...and in the recipient's mapping
      uint[] storage recipientCardIds = customerGiftCardIds[_recipientEIN];
      recipientCardIds.push(_giftCardId);

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


    /***************************************************************************
    *   Redeem functions
    ***************************************************************************/
    function redeem(
        uint _giftCardId, uint _amount, uint _timestamp,
        uint8 v, bytes32 r, bytes32 s
    ) public ensureSignatureTimeValid(_timestamp) {
      // GiftCard must exist
      require(giftCardsById[_giftCardId].id != 0, "Invalid giftCardId");
      uint _customerEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      GiftCard storage _giftCard = giftCardsById[_giftCardId];

      require(_giftCard.customer == _customerEIN, "You aren't the owner of this gift card.");
      require(_giftCard.balance > 0, "Can't redeem an empty gift card.");
      require(_giftCard.balance >= _amount, "Can't redeem more than gift card's balance");

      // Redemption must be signed by the customer
      require(
          isSigned(
              msg.sender,
              keccak256(
                  abi.encodePacked(
                      byte(0x19), byte(0), address(this),
                      "I authorize the redemption of this gift card.",
                      _giftCard.id, _amount, _timestamp
                  )
              ),
              v, r, s
          ),
          "Permission denied."
      );

      // Apply changes
      _giftCard.balance = _giftCard.balance.sub(_amount);
      redeemAllowed[_customerEIN][_giftCard.vendor].add(_amount);

      emit HydroGiftCardRedeemAllowed(_giftCardId, _giftCard.vendor, _giftCard.customer, _amount);
    }


    /***************************************************************************
    *   Public getters
    ***************************************************************************/
    function getGiftCardBalance(uint _giftCardId) public view returns (uint) {
      return giftCardsById[_giftCardId].balance;
    }

    function getGiftCard(uint _id)
      public view returns(
        string memory vendorCasedHydroID,
        string memory customerCasedHydroID,
        uint balance
    ) {
      GiftCard memory _giftCard = giftCardsById[_id];

      (address _address, string memory _vendorCasedHydroID) = clientRaindrop.getDetails(_giftCard.vendor);
      (address _address2, string memory _customerCasedHydroID) = clientRaindrop.getDetails(_giftCard.customer);
      return (_vendorCasedHydroID,_customerCasedHydroID,  _giftCard.balance);
    }

    function getCustomerGiftCardIds() public view returns(uint[] memory giftCardIds) {
      uint _buyerEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      return customerGiftCardIds[_buyerEIN];
    }


    event Debug(string);
    event Debug(uint);

    event HydroGiftCardOffersSet(uint indexed vendorEIN, uint[] amounts);
    event HydroGiftCardPurchased(uint indexed vendorEIN, uint indexed buyerEIN, uint amount);
    event HydroGiftCardRefunded(uint indexed id, uint indexed vendorEIN, uint indexed customerEIN, uint amount);
    event HydroGiftCardTransferred(uint indexed id, uint indexed buyerEIN, uint indexed recipientEIN);
    event HydroGiftCardRedeemAllowed(uint indexed id, uint indexed vendorEIN, uint indexed customerEIN, uint amount);
}
