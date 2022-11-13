// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

//0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f --> VRF Key Hash
//0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed --> VRFCoordinator

contract EatMoney is ERC1155, Ownable, VRFConsumerBaseV2 {
    // <---------------------Declarations------------------------------------>

    uint256 constant EAT_DECIMALS = 8;

    VRFCoordinatorV2Interface immutable COORDINATOR;
    bytes32 immutable s_keyHash;
    uint32 callbackGasLimit = 2500000;
    uint16 requestConfirmations = 3;
    uint64 s_subscriptionId;

    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

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

    struct EatPlate {
        uint256 id;
        uint256 efficiency;
        uint256 fortune;
        uint256 durablity;
        uint256 shiny;
        uint8 level;
        Category category;
    }

    struct MintRequest {
        uint8 category;
        uint256[] randomWords;
        bool isMinted;
    }
    MintRequest[] public mintRequests;
    EatPlate[] public plates;

    mapping(uint256 => EatPlate) public idToEatPlate;

    constructor(
        uint64 subscriptionId,
        address vrfCoordinator,
        bytes32 keyHash
    ) VRFConsumerBaseV2(vrfCoordinator) ERC1155("") {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_keyHash = keyHash;
        s_subscriptionId = subscriptionId;
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
            // todo
        }
    }

    function setURI(string memory newuri) public onlyOwner {
        _setURI(newuri);
    }

    function mintEatCoins(address account, uint256 amount) public onlyOwner {
        _mint(account, 0, amount * 10**EAT_DECIMALS, "");
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
            uint256 durability = (randomWords[randomWord % randomWords.length] %    // todo: improve algo if time permits
                ((10 + level * 10) / 2)) + 1;
                (((10 + level * 10) * 2) / 5)) + 1;
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
                Category(category)
            );

            plates.push(plate);
            idToEatPlate[id] = plate;
        }
        mintBatch(owner(), ids, amounts, "");
        mintRequests[reqIndex].isMinted = true;
    }
}
