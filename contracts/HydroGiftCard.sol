pragma solidity 0.5.0;

import "./SignatureVerifier.sol";
import "./zeppelin/ownership/Ownable.sol";
import "./zeppelin/math/SafeMath.sol";

import "./interfaces/ClientRaindropInterface.sol";
import "./interfaces/HydroInterface.sol";
import "./interfaces/IdentityRegistryInterface.sol";
import "./interfaces/SnowflakeInterface.sol";


interface giftCardRedeemer {
    function receiveRedeemApproval(uint _giftCardId, uint256 _value, address _giftCardContract, bytes calldata _extraData) external;
}


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
      uint id;          // unique GiftCard identifier
      uint vendor;      // vendor's EIN
      uint customer;    // customer's/recipient's EIN
      uint balance;     // amount of HYDRO remaining
      uint vendorRedeemAllowed;   // amount authorized for the vendor to transfer
    }

    // Mapping of customer's EIN to array of GiftCard IDs
    mapping(uint => uint[]) private customerGiftCardIds;

    // Mapping of vendor's EIN to array of GiftCard IDs
    mapping(uint => uint[]) private vendorGiftCardIds;

    mapping(uint => GiftCard) private giftCardsById;

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
    function setOffers(uint[] memory _amounts) public {
      uint _vendorEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      offers[_vendorEIN] = Offer(_amounts);
      emit HydroGiftCardOffersSet(_vendorEIN, _amounts);
    }

    function getOffers(uint _vendorEIN) public view returns (uint[] memory) {
      return offers[_vendorEIN].amounts;
    }

    function refundGiftCard(uint _giftCardId) public {
      /** Refund HYDRO to customer's Snowflake **/
      GiftCard storage giftCard = giftCardsById[_giftCardId];
      require(giftCard.id != 0, "Invalid giftCardId");
      uint _vendorEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN

      require(giftCard.vendor == _vendorEIN, "You don't have permission to refund this gift card");
      if (giftCard.balance == 0) {
        // Nothing to do
        return;
      }

      uint _amountToRefund = giftCard.balance;
      giftCard.balance = 0;

      // Approve refund to snowflake and call the Snowflake contract to accept
      hydroToken.approveAndCall(snowflakeAddress, _amountToRefund, abi.encode(giftCard.customer));

      emit HydroGiftCardRefunded(giftCard.id, giftCard.vendor, giftCard.customer, _amountToRefund);
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
      Offer memory vendorOffers = offers[_vendorEIN];
      bool offerFound = false;
      for (uint i=0; i<vendorOffers.amounts.length; i++) {
        if (vendorOffers.amounts[i] == _value) {
          offerFound = true;
          break;
        }
      }
      require(offerFound, "Vendor does not offer this denomination");

      // Transfer the HYDRO funds into the contract first...
      require(hydroToken.transferFrom(_sender, address(this), _value), "Transfer failed");

      // ...then add to the ledger
      maxGiftCardId += 1;
      GiftCard memory gc = GiftCard(maxGiftCardId, _vendorEIN, _buyerEIN, _value, 0);
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
      GiftCard storage giftCard = giftCardsById[_giftCardId];

      require(giftCard.customer == _customerEIN, "You aren't the owner of this gift card.");
      require(giftCard.balance > 0, "Can't redeem an empty gift card.");
      require(giftCard.balance >= _amount, "Can't redeem more than gift card's balance");

      // Redemption must be signed by the customer
      require(
          isSigned(
              msg.sender,
              keccak256(
                  abi.encodePacked(
                      byte(0x19), byte(0), address(this),
                      "I authorize the redemption of this gift card.",
                      giftCard.id, _amount, _timestamp
                  )
              ),
              v, r, s
          ),
          "Permission denied."
      );

      // Apply changes
      giftCard.balance = giftCard.balance.sub(_amount);
      giftCard.vendorRedeemAllowed = giftCard.vendorRedeemAllowed.add(_amount);

      emit HydroGiftCardRedeemAllowed(_giftCardId, giftCard.vendor, giftCard.customer, _amount);
    }

    function redeemAndCall(
      uint _giftCardId, uint _amount, uint _timestamp,
      uint8 v, bytes32 r, bytes32 s,
      address _vendorContractAddress, bytes memory _extraData
    ) public ensureSignatureTimeValid(_timestamp) {
      /** Version of redeem() that will automatically call the vendor's specified
          smart contract to accept the redemption and continue processing. **/

      // Will exit with exceptions if redemption authorization fails
      redeem(_giftCardId, _amount, _timestamp, v, r, s);

      // Invoke the vendor's redemption function in their smart contract
      giftCardRedeemer vendorContract = giftCardRedeemer(_vendorContractAddress);
      vendorContract.receiveRedeemApproval(_giftCardId, _amount, address(this), _extraData);
    }

    function vendorRedeem(uint _giftCardId, uint _amount) public {
      /*******************************************************************************
        Called within the vendor's receiveRedeemApproval() in their smart contract to
        actually transfer the HYDRO out of the GiftCard. To protect against vendor
        address spoofing, payment will ONLY go to the vendor's address that is linked
        in their identity; the GiftCard will not pay out to the calling address/smart
        contract.
      *******************************************************************************/
      GiftCard storage giftCard = giftCardsById[_giftCardId];

      require(giftCard.id != 0, "Not a valid giftCardId");
      require(giftCard.vendorRedeemAllowed >= _amount, "Redemption amount is greater than what is authorized");

      // Retrieve vendor's identity details from ClientRaindrop
      (address _vendorAddress, string memory vendorCasedHydroID) = clientRaindrop.getDetails(giftCard.vendor);

      // Update the GiftCard's allowance accounting...
      giftCard.vendorRedeemAllowed = giftCard.vendorRedeemAllowed.sub(_amount);

      // ...and only now do we do the transfer, and only to the address retrieved
      //  from the EIN identity.
      hydroToken.transfer(_vendorAddress, _amount);

      emit HydroGiftCardVendorRedeemed(_giftCardId, giftCard.vendor, giftCard.customer, _amount);
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

      (address _vendorAddress, string memory _vendorCasedHydroID) = clientRaindrop.getDetails(_giftCard.vendor);
      (address _customerAddress, string memory _customerCasedHydroID) = clientRaindrop.getDetails(_giftCard.customer);
      return (_vendorCasedHydroID, _customerCasedHydroID,  _giftCard.balance);
    }

    function getCustomerGiftCardIds() public view returns(uint[] memory giftCardIds) {
      uint _buyerEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      return customerGiftCardIds[_buyerEIN];
    }

    function getVendorGiftCardIds() public view returns(uint[] memory giftCardIds) {
      uint _vendorEIN = identityRegistry.getEIN(msg.sender);   // throws error if address not associated with an EIN
      return vendorGiftCardIds[_vendorEIN];
    }


    event Debug(string);
    event Debug(uint);

    event HydroGiftCardOffersSet(uint indexed vendorEIN, uint[] amounts);
    event HydroGiftCardPurchased(uint indexed vendorEIN, uint indexed buyerEIN, uint amount);
    event HydroGiftCardRefunded(uint indexed id, uint indexed vendorEIN, uint indexed customerEIN, uint amount);
    event HydroGiftCardTransferred(uint indexed id, uint indexed buyerEIN, uint indexed recipientEIN);
    event HydroGiftCardRedeemAllowed(uint indexed id, uint indexed vendorEIN, uint indexed customerEIN, uint amount);
    event HydroGiftCardVendorRedeemed(uint indexed id, uint indexed vendorEIN, uint indexed customerEIN, uint amount);
}
