const Bank = artifacts.require("Bank.sol");

module.exports = (deployer, network, [owner]) => {
    console.log(`network is ${network}`);

    deployer.then(async () => {
        await deployer.deploy(Bank);
        const bank = await Bank.deployed();
    });
};
