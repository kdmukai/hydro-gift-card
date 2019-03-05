const IdentityRegistry = artifacts.require('./_testing/IdentityRegistry.sol')
const HydroToken = artifacts.require('./_testing/HydroToken.sol')
const Snowflake = artifacts.require('./_testing/Snowflake.sol')
const ClientRaindrop = artifacts.require('./_testing/resolvers/ClientRaindrop/ClientRaindrop.sol')
const OldClientRaindrop = artifacts.require('./_testing/OldClientRaindrop.sol')
const HydroGiftCard = artifacts.require('./resolvers/HydroGiftCard.sol')
const VendorSampleContract = artifacts.require('./VendorSampleContract.sol')

async function initialize (owner, users, vendor1) {
  const instances = {}

  instances.HydroToken = await HydroToken.new({ from: owner })
  for (let i = 0; i < users.length; i++) {
    await instances.HydroToken.transfer(
      users[i].address,
      web3.utils.toBN(1000).mul(web3.utils.toBN(1e18)),
      { from: owner }
    )
  }

  instances.IdentityRegistry = await IdentityRegistry.new({ from: owner })

  instances.Snowflake = await Snowflake.new(
    instances.IdentityRegistry.address, instances.HydroToken.address, { from: owner }
  )

  instances.OldClientRaindrop = await OldClientRaindrop.new({ from: owner })

  instances.ClientRaindrop = await ClientRaindrop.new(
    instances.Snowflake.address, instances.OldClientRaindrop.address, 0, 0, { from: owner }
  )
  await instances.Snowflake.setClientRaindropAddress(instances.ClientRaindrop.address, { from: owner })

  instances.HydroGiftCard = await HydroGiftCard.new(
      instances.Snowflake.address, { from: owner }
  )

  instances.VendorSampleContract = await VendorSampleContract.new({ from: vendor1 })
  await instances.VendorSampleContract.setAddresses(instances.ClientRaindrop.address, { from: vendor1 })

  return instances
}

module.exports = {
  initialize: initialize
}
