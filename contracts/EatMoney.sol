// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

//0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f --> VRF Key Hash
//0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed --> VRFCoordinator

contract EatMoney is ERC1155, ERC1155Burnable, Ownable, VRFConsumerBaseV2 {
    // <---------------------Declarations------------------------------------>

    uint256 constant EAT_DECIMALS = 8;

    uint256 FACTOR_1 = 1; //cofficent for efficency (will change according to the market)
    uint256 FACTOR_2 = 3; // random start
    uint256 FACTOR_3 = 5; // random end

    VRFCoordinatorV2Interface immutable COORDINATOR;
    bytes32 immutable s_keyHash;
    uint32 callbackGasLimit = 2500000;
    uint16 requestConfirmations = 3;
    uint64 s_subscriptionId;

    AggregatorV3Interface internal priceFeed;

    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;
    Counters.Counter private _restaurants;

    enum Category {
        BRONZE,
        SILVER,
        GOLD,
        SAPHIRE
    }

    enum ChainlinkRequestType {
        MINT,
        EAT
    }

    mapping(uint256 => ChainlinkRequestType) public chailinkRequestsTypes;
    mapping(uint256 => uint8) public reqIdTocategory;

    mapping(uint256 => EatRequest) public reqIdToEatRequest;

    struct EatPlate {
        uint256 id;
        uint256 efficiency;
        uint256 fortune;
        uint256 durablity;
        uint256 shiny;
        uint8 level;
        Category category;
        uint256 lastEat;
    }

    struct MintRequest {
        uint8 category;
        uint256[] randomWords;
        bool isMinted;
    }

    struct EatRequest {
        uint256 plateId;
        address owner;
        uint256 restaurantId;
        uint256 amount;
        bool active;
    }

    MintRequest[] public mintRequests;
    EatPlate[] public plates;

    mapping(uint256 => EatPlate) public idToEatPlate;
    mapping(uint256 => Restaurant) public idToRestaurant;

    struct Restaurant {
        uint256 id;
        string info;
        address payable owner;
    }

    event EatFinished(
        uint256 plateId,
        uint256 restaurantId,
        uint256 amount,
        uint256 eatCoinsMinted
    );

    constructor(
        uint64 subscriptionId,
        address vrfCoordinator,
        bytes32 keyHash
    ) VRFConsumerBaseV2(vrfCoordinator) ERC1155("") {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_keyHash = keyHash;
        s_subscriptionId = subscriptionId;
        priceFeed = AggregatorV3Interface(
            0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada
        ); //MATIC/USD price feed mumbai
    }

    // <---------------------Functions------------------------------------>

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        ChainlinkRequestType requestType = chailinkRequestsTypes[requestId];
        if (requestType == ChainlinkRequestType.MINT) {
            mintRequests.push(
                MintRequest(reqIdTocategory[requestId], randomWords, false)
            );
        } else if (requestType == ChainlinkRequestType.EAT) {
            _finishEat(requestId, randomWords);
        }
    }

    function setURI(string memory newuri) public onlyOwner {
        _setURI(newuri);
    }

    function getLatestPrice() public view returns (int256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return price;
    }

    function mintEatCoins(address account, uint256 amount) public onlyOwner {
        _mint(account, 0, amount, "");
    }

    function mint(
        uint32 amount, // max 500 at one time
        uint8 category // 0: bronze, 1: silver, 2: gold, 3: saphire
    ) public onlyOwner {
        uint256 requestId = COORDINATOR.requestRandomWords(
            s_keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            amount
        );

        chailinkRequestsTypes[requestId] = ChainlinkRequestType.MINT;
        reqIdTocategory[requestId] = category;
    }

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public onlyOwner {
        _mintBatch(to, ids, amounts, data);
    }

    function _mintEatPlate(uint256 reqIndex) public onlyOwner {
        require(reqIndex <= mintRequests.length, "Invalid request index");
        require(mintRequests[reqIndex].isMinted == false, "Already minted");

        uint256[] memory randomWords = mintRequests[reqIndex].randomWords;
        uint8 category = mintRequests[reqIndex].category;
        uint256[] memory ids = new uint256[](randomWords.length);
        uint256[] memory amounts = new uint256[](randomWords.length);
        for (uint256 i = 0; i < randomWords.length; i++) {
            uint256 randomWord = randomWords[i];
            uint8 level = uint8(randomWord % 4) + 1;
            // level 1-->20, 2-->30, 3-->40, 4-->50
            uint256 efficiency = (randomWord % ((10 + level * 10) / 2)) + 1;
            uint256 durability = (randomWords[randomWord % randomWords.length] % // todo: improve algo if time permits
                ((10 + level * 10) / 2)) + 1;
            (((10 + level * 10) * 2) / 5) + 1;
            uint256 fortune = (10 + (level * 10)) - efficiency - durability;

            _tokenIds.increment();
            uint256 id = _tokenIds.current();

            ids[i] = id;
            amounts[i] = 1;
            EatPlate memory plate = EatPlate(
                id,
                efficiency,
                fortune,
                durability,
                100,
                level,
                Category(category),
                0
            );

            plates.push(plate);
            idToEatPlate[id] = plate;
        }
        mintBatch(owner(), ids, amounts, "");
        mintRequests[reqIndex].isMinted = true;
    }

    function registerRestaurant(
        string calldata restaurantInfo,
        address restaurantAddress
    ) public onlyOwner {
        require(restaurantAddress != address(0), "Invalid address");
        _restaurants.increment();
        uint256 id = _restaurants.current();
        idToRestaurant[id] = Restaurant(
            id,
            restaurantInfo,
            payable(restaurantAddress)
        );
    }

    function eat(
        uint256 plateId,
        uint256 restaurantId,
        bytes memory signature,
        uint256 nonce,
        string memory message,
        uint256 amount // amount in dollars * 10**6
    ) public payable {
        require(
            balanceOf(msg.sender, plateId) == 1,
            "You don't have this plate"
        );

        EatPlate memory plate = idToEatPlate[plateId];
        uint256 amountCap = 0;

        if (plate.category == Category.BRONZE) {
            amountCap = 5000000;
        } else if (plate.category == Category.SILVER) {
            amountCap = 15000000;
        } else if (plate.category == Category.GOLD) {
            amountCap = 50000000;
        } else if (plate.category == Category.SAPHIRE) {
            amountCap = 100000000;
        }

        require(amount <= amountCap, "Amount exceeds plate max cap");
        require(
            verify(
                idToRestaurant[restaurantId].owner,
                message,
                nonce,
                signature
            ),
            "Invalid signature"
        );
        require(
            plate.lastEat + 1 days < block.timestamp,
            "You can eat only once a day"
        );
        uint256 price = uint256(getLatestPrice());
        uint256 amountInMatic = amount * price * 10**4;
        require(amountInMatic <= msg.value, "Not enough MATIC sent");
        idToRestaurant[restaurantId].owner.transfer(msg.value);
        uint256 requestId = COORDINATOR.requestRandomWords(
            s_keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );

        chailinkRequestsTypes[requestId] = ChainlinkRequestType.EAT;
        reqIdToEatRequest[requestId] = EatRequest(
            plateId,
            msg.sender,
            restaurantId,
            amount,
            false
        );
    }

    function _finishEat(uint256 requestId, uint256[] memory randomWords)
        internal
    {
        EatRequest memory eatRequest = reqIdToEatRequest[requestId];
        require(
            eatRequest.active == false,
            "Aleady claimed eat coins for this request"
        );
        EatPlate memory plate = idToEatPlate[eatRequest.plateId];
        uint256 randomWord = randomWords[0];
        uint256 randFactor = (randomWord % (FACTOR_3 - FACTOR_2 + 1)) +
            FACTOR_2;
        uint256 eatCoins = ((plate.efficiency**FACTOR_1) *
            eatRequest.amount *
            10**2) / randFactor;
        idToEatPlate[eatRequest.plateId].lastEat = block.timestamp;
        reqIdToEatRequest[requestId].active = true;

        mintEatCoins(eatRequest.owner, eatCoins);

        emit EatFinished(
            eatRequest.plateId,
            eatRequest.restaurantId,
            eatRequest.amount,
            eatCoins
        );
    }

    function getMessageHash(string memory _message, uint256 _nonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_message, _nonce));
    }

    function getEthSignedMessageHash(bytes32 _messageHash)
        public
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    _messageHash
                )
            );
    }

    function verify(
        address _signer,
        string memory _message,
        uint256 _nonce,
        bytes memory signature
    ) public pure returns (bool) {
        bytes32 messageHash = getMessageHash(_message, _nonce);
        bytes32 ethSignedMessageHash = getEthSignedMessageHash(messageHash);

        return recoverSigner(ethSignedMessageHash, signature) == _signer;
    }

    function recoverSigner(
        bytes32 _ethSignedMessageHash,
        bytes memory _signature
    ) public pure returns (address) {
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signature);

        return ecrecover(_ethSignedMessageHash, v, r, s);
    }

    function splitSignature(bytes memory sig)
        public
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v
        )
    {
        require(sig.length == 65, "invalid signature length");

        assembly {
            r := mload(add(sig, 32))

            s := mload(add(sig, 64))

            v := byte(0, mload(add(sig, 96)))
        }

        // implicitly return (r, s, v)
    }
}
