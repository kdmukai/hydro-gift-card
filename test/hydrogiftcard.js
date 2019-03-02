const common = require('./common.js')
const { sign, verifyIdentity } = require('./utilities')

let user
let instances

contract('Testing HydroGiftCard', function (accounts) {
  const owner = accounts[0]

  let vendor1 = {
    hydroID: 'vendor1',
    address: accounts[1],
    recoveryAddress: accounts[1],
    private: '0x6bf410ff825d07346c110c5836b33ec76e7d1ee051283937392180b732aa3aff',
    identity: web3.utils.toBN(1)
  }
  let vendor2 = {
    hydroID: 'vendor2',
    address: accounts[2],
    recoveryAddress: accounts[2],
    private: '0xccc3c84f02b038a5d60d93977ab11eb57005f368b5f62dad29486edeb4566954',
    identity: web3.utils.toBN(2)
  }
  let customer1 = {
    hydroID: 'customer1',
    address: accounts[3],
    recoveryAddress: accounts[3],
    private: '0xfdf12368f9e0735dc01da9db58b1387236120359024024a31e611e82c8853d7f',
    identity: web3.utils.toBN(3)
  }
  let customer2 = {
    hydroID: 'customer2',
    address: accounts[4],
    recoveryAddress: accounts[4],
    private: '0x44e02845db8861094c519d72d08acb7435c37c57e64ec5860fb15c5f626cb77c',
    identity: web3.utils.toBN(4)
  }
  let other1 = {
    address: accounts[5],
    private: '0x12093c3cd8e0c6ceb7b1b397724cd82c4d84f81263f56a44f11d8bd3a61ffccb',
  }

  const offerAmounts = [
    web3.utils.toWei("1000", "gwei"),
    web3.utils.toWei("5000", "gwei"),
    web3.utils.toWei("10000", "gwei"),
  ]

  it('common contracts deployed', async () => {
    instances = await common.initialize(accounts[0], [])
  })

  async function createSnowflakeIdentity(_user) {
    const timestamp = Math.round(new Date() / 1000) - 1
    const permissionString = web3.utils.soliditySha3(
      '0x19', '0x00', instances.IdentityRegistry.address,
      'I authorize the creation of an Identity on my behalf.',
      _user.recoveryAddress,
      _user.address,
      { t: 'address[]', v: [instances.Snowflake.address] },
      { t: 'address[]', v: [] },
      timestamp
    )

    const permission = await sign(permissionString, _user.address, _user.private)

    await instances.Snowflake.createIdentityDelegated(
      _user.recoveryAddress, _user.address, [], _user.hydroID, permission.v, permission.r, permission.s, timestamp
    )

    await verifyIdentity(_user.identity, instances.IdentityRegistry, {
      recoveryAddress:     _user.recoveryAddress,
      associatedAddresses: [_user.address],
      providers:           [instances.Snowflake.address],
      resolvers:           [instances.ClientRaindrop.address]
    })
  }

  describe('Test HydroToken', async () => {
    it('can transfer HYDRO tokens', async function () {
      let amount = web3.utils.toBN(offerAmounts[0]).mul(web3.utils.toBN('50'))
      await instances.HydroToken.transfer(
        customer1.address,
        amount,
        { from: accounts[0] }
      )

      let customerBalance = await instances.HydroToken.balanceOf(customer1.address)
      assert(customerBalance.gt(web3.utils.toBN('0')), "Customer1 did not receive HYDRO")
      assert(customerBalance.eq(amount), "Customer1 did not receive the correct amount of HYDRO")

      // Also seed 'other1' with HYDRO for later tests
      await instances.HydroToken.transfer(
        other1.address,
        amount,
        { from: accounts[0] }
      )
    })
  })

  describe('Test Snowflake', async () => {
    it('Identities can be created', async function () {
      await createSnowflakeIdentity(vendor1)
      await createSnowflakeIdentity(vendor2)
      await createSnowflakeIdentity(customer1)
      await createSnowflakeIdentity(customer2)

      // Confirm that we can retrieve their info from the registry
      let ein = await instances.IdentityRegistry.getEIN(customer1.address)
      assert(ein.eq(customer1.identity))

      await instances.IdentityRegistry.getIdentity(ein)

      // Returns (uint ein, address _address, string memory casedHydroID)
      let details = await instances.ClientRaindrop.getDetails(customer1.hydroID)
      assert(details[2] == customer1.hydroID)
    })
  })

  // describe('Test Client Raindrop', async () => {
  //   it('User can sign up', async function () {
  //     await instances.ClientRaindrop.signUpUser(customer1.name, { from: customer1.public })
  //   })
  // })

  describe('Test HydroGiftCard', async () => {
    it('Says Hello, World', async function () {
      assert.equal(await instances.HydroGiftCard.helloWorld(), "Hello, World")
    })

    it('vendor w/identity can set Offers', async function () {
      // The vendor can set their Offer from one of their own associated addresses...
      await instances.HydroGiftCard.setOffer(offerAmounts, { from: vendor1.address })

      // Confirm the vendor's first offer...
      let retrievedAmounts = await instances.HydroGiftCard.getOffer(vendor1.identity)
      assert.equal(retrievedAmounts[0].valueOf(), offerAmounts[0])

      // And expect nothing for the other vendor
      assert.equal(await instances.HydroGiftCard.getOffer(vendor2.identity), 0)
    })

    it('vendor w/out identity can\'t set Offers', async function () {
      await instances.HydroGiftCard.setOffer(offerAmounts, { from: other1.address })
        .then(() => assert.fail('address with no identity created Offers', 'call should fail'))
        .catch(error => assert.include(error.message, 'The passed address does not have an identity but should', 'unexpected error'))
    })

    it('Buyer w/identity and sufficient HYDRO can buy a vendor\'s Offer', async function () {
      let customerBalance = await instances.HydroToken.balanceOf(customer1.address)
      assert(customerBalance.gt(web3.utils.toBN(offerAmounts[0])), "Customer1 does not have enough HYDRO")

      // call approveAndCall so that it triggers HydroGiftCard's receiveApproval
      await instances.HydroToken.approveAndCall(
        instances.HydroGiftCard.address,
        offerAmounts[0],
        web3.eth.abi.encodeParameter('uint256', vendor1.identity.toNumber()),
        { from: customer1.address }
      )

      let giftCardIds = await instances.HydroGiftCard.getCustomerGiftCardIds({ from: customer1.address })

      // returns (string memory vendorCasedHydroID, uint balance)
      let details = await instances.HydroGiftCard.getGiftCard(giftCardIds[0])
      assert(details[1].eq(web3.utils.toBN(offerAmounts[0])), "GiftCard initial balance does not match original Offer")
    })

    it('Buyer w/out sufficient HYDRO cannot buy a vendor\'s Offer', async function () {
      // Customer2 has no HYDRO yet
      let customerBalance = await instances.HydroToken.balanceOf(customer2.address)
      assert(customerBalance.lt(web3.utils.toBN(offerAmounts[0])), "Customer2 has too much HYDRO for this test")

      // call approveAndCall so that it triggers HydroGiftCard's receiveApproval
      await instances.HydroToken.approveAndCall(
        instances.HydroGiftCard.address,
        offerAmounts[0],
        web3.eth.abi.encodeParameter('uint256', vendor1.identity.toNumber()),
        { from: customer2.address }
      )
        .then(() => assert.fail('GiftCard was purchased with unsufficient HYDRO', 'purchase should fail'))
        .catch(error => assert.include(error.message, 'Insufficient balance', 'unexpected error'))

      let giftCardIds = await instances.HydroGiftCard.getCustomerGiftCardIds({ from: customer2.address })
      assert(giftCardIds.length == 0)
    })

    it('Buyer w/out identity can\'t buy a vendor\'s Offer', async function () {
      let customerBalance = await instances.HydroToken.balanceOf(customer1.address)
      assert(customerBalance.gt(web3.utils.toBN(offerAmounts[0])), "Customer1 does not have enough HYDRO")

      // call approveAndCall so that it triggers HydroGiftCard's receiveApproval
      await instances.HydroToken.approveAndCall(
        instances.HydroGiftCard.address,
        offerAmounts[0],
        web3.eth.abi.encodeParameter('uint256', vendor1.identity.toNumber()),
        { from: other1.address }
      )
        .then(() => assert.fail('bought GiftCard without having an identity', 'transaction should fail'))
        .catch(error => assert.include(error.message, 'The passed address does not have an identity but should', 'unexpected error'))
    })

    it('Buyer that doesn\'t encode vendorEIN can\'t buy a vendor\'s Offer', async function () {
      let customerBalance = await instances.HydroToken.balanceOf(customer1.address)
      assert(customerBalance.gt(web3.utils.toBN(offerAmounts[0])), "Customer1 does not have enough HYDRO")

      // call approveAndCall so that it triggers HydroGiftCard's receiveApproval
      await instances.HydroToken.approveAndCall(
        instances.HydroGiftCard.address,
        offerAmounts[0],
        0,
        { from: customer1.address }
      )
        .then(() => assert.fail('bought GiftCard without encoding vendorEIN', 'transaction should fail'))
        .catch(error => assert.include(error.message, 'invalid bytes value', 'unexpected error'))
    })

    it('Buyer that encodes unknown vendorEIN can\'t buy a vendor\'s Offer', async function () {
      let customerBalance = await instances.HydroToken.balanceOf(customer1.address)
      assert(customerBalance.gt(web3.utils.toBN(offerAmounts[0])), "Customer1 does not have enough HYDRO")

      // call approveAndCall so that it triggers HydroGiftCard's receiveApproval
      await instances.HydroToken.approveAndCall(
        instances.HydroGiftCard.address,
        offerAmounts[0],
        web3.eth.abi.encodeParameter('uint256', 123456),
        { from: customer1.address }
      )
        .then(() => assert.fail('bought GiftCard without encoding a known vendorEIN', 'transaction should fail'))
        .catch(error => assert.include(error.message, 'The recipient EIN does not exist', 'unexpected error'))
    })

    it('Buyer can\'t buy from a vendor with no Offers', async function () {
      let customerBalance = await instances.HydroToken.balanceOf(customer1.address)
      assert(customerBalance.gt(web3.utils.toBN(offerAmounts[0])), "Customer1 does not have enough HYDRO")

      // call approveAndCall so that it triggers HydroGiftCard's receiveApproval
      await instances.HydroToken.approveAndCall(
        instances.HydroGiftCard.address,
        offerAmounts[0],
        web3.eth.abi.encodeParameter('uint256', vendor2.identity.toNumber()),
        { from: customer1.address }
      )
        .then(() => assert.fail('bought GiftCard from vendor with no Offers', 'transaction should fail'))
        .catch(error => assert.include(error.message, 'Vendor has no available offers', 'unexpected error'))
    })

    // it('Buyer can gift to recipient', async function () {
    //   assert(false);
    // })
  })
})
