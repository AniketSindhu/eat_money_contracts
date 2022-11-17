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
    Counters.Counter private _listings;
    enum Category {
        BRONZE,
        SILVER,
        GOLD,
        EMERALD
    }

    enum ChainlinkRequestType {
        MINT,
        EAT,
        SPIN
    }

    mapping(uint256 => ChainlinkRequestType) public chailinkRequestsTypes;
    mapping(uint256 => uint8) public reqIdTocategory;

    mapping(uint256 => EatRequest) public reqIdToEatRequest;
    mapping(uint256 => SpinRequest) public reqIdToSpinRequest;

    struct EatPlate {
        uint256 id;
        uint256 efficiency;
        uint256 fortune;
        uint256 durablity;
        uint256 shiny;
        uint8 level;
        Category category;
        uint256 lastEat;
        uint256 eats;
        Spin[] spins;
    }

    struct MintRequest {
        uint8 category;
        uint256[] randomWords;
        bool isMinted;
    }

    struct SpinRequest {
        uint256 plateId;
        address owner;
        uint256 eatCoins;
        bool active;
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

    struct Spin {
        uint256 spinId;
        uint32 result; //   1/2/3/4
        uint256 eatCoins;
        bool isSpinned;
    }

    struct MarketItem {
        uint256 id;
        uint256 price;
        address payable owner;
        bool active;
        uint256 tokenId;
    }

    mapping(uint256 => MarketItem) public idToMarketplaceItem;

    struct Restaurant {
        uint256 id;
        string info;
        address payable owner;
    }

    mapping(address => uint256) public addressToRestaurantId;

    event EatFinished(
        uint256 plateId,
        uint256 restaurantId,
        uint256 amount,
        uint256 eatCoinsMinted
    );

    event LevelUp(
        uint256 plateId,
        uint256 efficency,
        uint256 fortune,
        uint256 durability,
        uint256 level
    );

    event SpinFinished(uint256 plateId, uint256 spinId, uint256 eatCoinsWon);

    constructor(
        uint64 subscriptionId,
        address vrfCoordinator,
        bytes32 keyHash
    )
        VRFConsumerBaseV2(vrfCoordinator)
        ERC1155(
            "ipfs://bafybeickwso5eac5krffgzdk2ktfg5spnryiygk3mbenryxdsapg3a54va/"
        )
    {
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
        } else if (requestType == ChainlinkRequestType.SPIN) {
            _finishSpin(requestId, randomWords);
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
                0,
                0,
                new Spin[](0)
            );

            plates.push(plate);
            idToEatPlate[id] = plate;
        }
        mintBatch(owner(), ids, amounts, "");
        mintRequests[reqIndex].isMinted = true;
    }

    //change factors
    function changeFactor(
        uint256 factor1,
        uint256 factor2,
        uint256 factor3
    ) public onlyOwner {
        require(factor2 < factor3, "Factor 2 should be less than factor 3");
        FACTOR_1 = factor1;
        FACTOR_2 = factor2;
        FACTOR_3 = factor3;
    }

    function registerRestaurant(
        string calldata restaurantInfo,
        address restaurantAddress
    ) public {
        require(restaurantAddress != address(0), "Invalid address");
        require(
            addressToRestaurantId[restaurantAddress] == 0,
            "Restaurant already registered"
        );
        _restaurants.increment();
        uint256 id = _restaurants.current();
        safeTransferFrom(
            msg.sender,
            address(this),
            0,
            2000 * 10**EAT_DECIMALS,
            ""
        );
        addressToRestaurantId[restaurantAddress] = id;
        idToRestaurant[id] = Restaurant(
            id,
            restaurantInfo,
            payable(restaurantAddress)
        );
    }

    // delete restaurant, return stake
    function deleteRestaurant(address restaurantAddress) public {
        require(restaurantAddress != address(0), "Invalid address");
        uint256 id = addressToRestaurantId[restaurantAddress];
        require(id != 0, "Restaurant not registered");
        delete idToRestaurant[id];
        delete addressToRestaurantId[restaurantAddress];
        safeTransferFrom(
            address(this),
            restaurantAddress,
            0,
            2000 * 10**EAT_DECIMALS,
            ""
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
        } else if (plate.category == Category.EMERALD) {
            amountCap = 100000000;
        }

        require(amount <= amountCap, "Amount exceeds plate max cap");
        require(plate.shiny > 0, "Plate too dirty, clean to use it");
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
        uint256 shinyFactor = 100;
        if (plate.shiny <= 60) {
            shinyFactor = 111; // earning drop to 90% if shiny is less than 60
        } else if (plate.shiny <= 20) {
            shinyFactor = 1000; // earning drop to 10% if shiny is less than 20
        }
        uint256 randomWord = randomWords[0];
        uint256 randFactor = (randomWord % (FACTOR_3 - FACTOR_2 + 1)) +
            FACTOR_2;
        uint256 eatCoins = ((plate.efficiency**FACTOR_1) *
            eatRequest.amount *
            10**4) / (randFactor * shinyFactor);
        idToEatPlate[eatRequest.plateId].lastEat = block.timestamp;
        idToEatPlate[eatRequest.plateId].shiny -= 10;
        reqIdToEatRequest[requestId].active = true;
        idToEatPlate[eatRequest.plateId].spins.push(
            Spin(plate.eats, 0, eatCoins, false)
        );
        idToEatPlate[eatRequest.plateId].eats += 1;
        mintEatCoins(eatRequest.owner, eatCoins);

        emit EatFinished(
            eatRequest.plateId,
            eatRequest.restaurantId,
            eatRequest.amount,
            eatCoins
        );
    }

    function spinWheel(uint256 plateId) public {
        require(
            balanceOf(msg.sender, plateId) == 1,
            "You don't have this plate"
        );
        EatPlate memory plate = idToEatPlate[plateId];
        require(plate.spins.length > 0, "No spins available");
        require(
            plate.spins[plate.spins.length - 1].isSpinned == false,
            "Last eat spin already done"
        );
        require(
            plate.lastEat + 5 minutes < block.timestamp,
            "You can spin only after 5 minutes of last eat"
        );
        burn(msg.sender, plateId, 30**EAT_DECIMALS);
        uint256 requestId = COORDINATOR.requestRandomWords(
            s_keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );
        chailinkRequestsTypes[requestId] = ChainlinkRequestType.SPIN;
        reqIdToSpinRequest[requestId] = SpinRequest(
            plateId,
            msg.sender,
            plate.spins[plate.spins.length - 1].eatCoins,
            false
        );
    }

    function _finishSpin(uint256 requestId, uint256[] memory randomWords)
        internal
    {
        SpinRequest memory spinRequest = reqIdToSpinRequest[requestId];
        require(spinRequest.active == false, "Aleady spinned for this request");
        EatPlate memory plate = idToEatPlate[spinRequest.plateId];
        uint256 randomWord = randomWords[0] % 1000;
        //more odds based on fortune
        uint32 result = 0;
        uint256 eatCoinsWon = 0;
        if (randomWord < plate.fortune * 10) {
            if (randomWord < plate.fortune * 2) {
                result = 4;
                eatCoinsWon = spinRequest.eatCoins / 3;
            } else if (randomWord < plate.fortune * 5) {
                result = 3;
                eatCoinsWon = spinRequest.eatCoins / 5;
            } else {
                result = 2;
                eatCoinsWon = spinRequest.eatCoins / 10;
            }
        } else {
            result = 1;
            eatCoinsWon = 0;
        }
        idToEatPlate[spinRequest.plateId]
            .spins[plate.spins.length - 1]
            .result = result;
        idToEatPlate[spinRequest.plateId]
            .spins[plate.spins.length - 1]
            .isSpinned = true;

        reqIdToSpinRequest[requestId].active = true;

        if (eatCoinsWon > 0) {
            mintEatCoins(spinRequest.owner, eatCoinsWon);
        }

        emit SpinFinished(
            spinRequest.plateId,
            plate.spins.length - 1,
            eatCoinsWon
        );
    }

    function levelUp(
        uint256 efficency,
        uint256 fortune,
        uint256 durability,
        uint256 plateId
    ) public {
        require(
            balanceOf(msg.sender, plateId) == 1,
            "You don't have this plate"
        );
        EatPlate memory plate = idToEatPlate[plateId];
        require(plate.level < 4, "Plate is already max level");
        require(
            efficency + fortune + durability == 10,
            "Invalid points allocation"
        );
        uint256 amount = 0;
        if (plate.level == 1) {
            amount = 100 * 10**EAT_DECIMALS;
        } else if (plate.level == 2) {
            amount = 180 * 10**EAT_DECIMALS;
        } else if (plate.level == 3) {
            amount = 350 * 10**EAT_DECIMALS;
        }
        burn(msg.sender, 0, amount);
        //safeTransferFrom(msg.sender, address(this), 0, amount, "");
        idToEatPlate[plateId].efficiency += efficency;
        idToEatPlate[plateId].fortune += fortune;
        idToEatPlate[plateId].durablity += durability;
        idToEatPlate[plateId].level += 1;

        emit LevelUp(
            plateId,
            efficency,
            fortune,
            durability,
            idToEatPlate[plateId].level
        );
    }

    function clean(uint256 plateId) public {
        require(
            balanceOf(msg.sender, plateId) == 1,
            "You don't have this plate"
        );
        EatPlate memory plate = idToEatPlate[plateId];
        require(plate.shiny < 100, "Plate is already shiny");
        uint256 costPerShiny = (10**EAT_DECIMALS * plate.level * 12) /
            (plate.durablity**2);
        uint256 amount = (100 - plate.shiny) * costPerShiny;
        burn(msg.sender, 0, amount);
        //safeTransferFrom(msg.sender, address(this), 0, amount, "");
        idToEatPlate[plateId].shiny = 100;
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

    //<------------------------------Marketplace functions-------------------------------------------->

    //function to list nft
    function listPlate(uint256 plateId, uint256 price) public {
        require(
            idToEatPlate[plateId].shiny == 100,
            "Clean your plate before selling"
        );
        _listings.increment();
        idToMarketplaceItem[_listings.current()] = MarketItem(
            _listings.current(),
            price,
            payable(msg.sender),
            true,
            plateId
        );
        _safeTransferFrom(msg.sender, address(this), plateId, 1, "");
        //emit Listed(plateId, price);
    }

    //function to buy nft
    function buyPlate(uint256 listingId) public payable {
        //todo restricts users from buying multiple plates
        MarketItem memory listing = idToMarketplaceItem[listingId];
        require(
            getPlatesOfOwner(msg.sender).id != 0,
            "You already have a plate, EAT ON THAT"
        );
        require(listing.active, "Listing is not active");
        require(listing.price == msg.value, "Price is not correct");
        _safeTransferFrom(address(this), msg.sender, listing.tokenId, 1, "");
        listing.owner.transfer(msg.value);
        idToMarketplaceItem[listingId].active = false;
        //emit Bought(listingId);
    }

    //function to view all active listings
    function getMarketplaceItems() public view returns (MarketItem[] memory) {
        uint256 totalListings = _listings.current();
        MarketItem[] memory items = new MarketItem[](totalListings);
        uint256 index = 0;
        for (uint256 i = 1; i <= totalListings; i++) {
            if (idToMarketplaceItem[i].active) {
                items[index] = idToMarketplaceItem[i];
                index++;
            }
        }
        return items;
    }

    // <--------------------------------Marketplace functions end------------------------------------>

    // <--------------------------------Views------------------------------------>
    //view function to get all plates of an address
    function getPlatesOfOwner(address _owner)
        public
        view
        returns (EatPlate memory)
    {
        uint256 plateId = 0;
        for (uint256 i = 1; i <= _tokenIds.current(); i++) {
            if (balanceOf(_owner, i) > 0) {
                plateId = i;
                break;
            }
        }
        if (plateId == 0) {
            return EatPlate(0, 0, 0, 0, 0, 0, Category(0), 0, 0, new Spin[](0));
        } else {
            return idToEatPlate[plateId];
        }
    }

    //view function to get restaurant details from address
    function getRestaurantDetails(address _owner)
        public
        view
        returns (Restaurant memory)
    {
        return idToRestaurant[addressToRestaurantId[_owner]];
    }

    // <--------------------------------Views------------------------------------>

    function uri(uint256 id)
        public
        view
        virtual
        override
        returns (string memory)
    {
        EatPlate memory plate = idToEatPlate[id];
        if (plate.category == Category.BRONZE) {
            if (plate.level == 1) {
                return string(abi.encodePacked(super.uri(id), "bronze_1.json"));
            } else if (plate.level == 2) {
                return string(abi.encodePacked(super.uri(id), "bronze_2.json"));
            } else if (plate.level == 3) {
                return string(abi.encodePacked(super.uri(id), "bronze_3.json"));
            } else {
                return string(abi.encodePacked(super.uri(id), "bronze_4.json"));
            }
        } else if (plate.category == Category.SILVER) {
            if (plate.level == 1) {
                return string(abi.encodePacked(super.uri(id), "silver_1.json"));
            } else if (plate.level == 2) {
                return string(abi.encodePacked(super.uri(id), "silver_2.json"));
            } else if (plate.level == 3) {
                return string(abi.encodePacked(super.uri(id), "silver_3.json"));
            } else {
                return string(abi.encodePacked(super.uri(id), "silver_4.json"));
            }
        } else if (plate.category == Category.GOLD) {
            if (plate.level == 1) {
                return string(abi.encodePacked(super.uri(id), "gold_1.json"));
            } else if (plate.level == 2) {
                return string(abi.encodePacked(super.uri(id), "gold_2.json"));
            } else if (plate.level == 3) {
                return string(abi.encodePacked(super.uri(id), "gold_3.json"));
            } else {
                return string(abi.encodePacked(super.uri(id), "gold_4.json"));
            }
        } else {
            if (plate.level == 1) {
                return
                    string(abi.encodePacked(super.uri(id), "emerald_1.json"));
            } else if (plate.level == 2) {
                return
                    string(abi.encodePacked(super.uri(id), "emerald_2.json"));
            } else if (plate.level == 3) {
                return
                    string(abi.encodePacked(super.uri(id), "emerald_3.json"));
            } else {
                return
                    string(abi.encodePacked(super.uri(id), "emerald_4.json"));
            }
        }
    }
}
