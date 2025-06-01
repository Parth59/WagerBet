// SPDX-License-Identifier: MIT
pragma solidity ^ 0.8.20;

import {PredeployAddresses} from "@interop-lib/libraries/PredeployAddresses.sol";
import {CrossDomainMessageLib} from "@interop-lib/libraries/CrossDomainMessageLib.sol";
import {IL2ToL2CrossDomainMessenger} from "@interop-lib/interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ISuperchainETHBridge} from "@interop-lib/interfaces/ISuperchainETHBridge.sol";

contract WagerBet {
    uint256 public betCounter;
    address public owner;

    ISuperchainETHBridge internal immutable superchainETHBridge = ISuperchainETHBridge(payable(PredeployAddresses.SUPERCHAIN_ETH_BRIDGE));
    IL2ToL2CrossDomainMessenger internal immutable l2ToL2CrossDomainMessenger =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    enum BetStatus { Open, Joined, Resolved }

    struct Bet {
        uint256 id;
        uint256 creatorChainId;
        uint256 joinerChainId;
        address creator;
        address joiner;
        address resolver;
        string description;
        uint256 stake;
        address winner;
        BetStatus status;
        uint256 expiryTimestamp;
    }

    mapping(uint256 => Bet) public bets;

    event BetCreated(uint256 indexed id, address indexed creator, string description, uint256 stake, uint256 expiryTimestamp, address resolver);
    event BetResolved(uint256 indexed id, address indexed winner);
    event BetExpired(uint256 indexed id);
    event BetJoinedDetailed(
        uint256 indexed betId,
        address indexed creator,
        address indexed joiner,
        uint256 stake,
        uint256 joinerChainId,
        BetStatus status
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the contract owner");
        _;
    }

    modifier onlyOpen(uint256 betId) {
        require(bets[betId].status == BetStatus.Open, "Bet is not open");
        require(block.timestamp < bets[betId].expiryTimestamp, "Bet has expired");
        _;
    }

    modifier onlyJoined(uint256 betId) {
        require(bets[betId].status == BetStatus.Joined, "Bet not yet joined");
        require(block.timestamp < bets[betId].expiryTimestamp, "Bet has expired");
        _;
    }

    modifier onlyResolver(uint256 betId) {
        require(bets[betId].resolver == msg.sender, "Not the bet resolver");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function createBet(uint256 _destinationChainId, string memory description, uint256 _expiryTimestamp, address _resolver) public payable returns (bytes32)  {
        require(msg.value > 0, "Must send some ETH to stake");
        require(_expiryTimestamp > block.timestamp, "Expiry must be in the future");
        require(_resolver != address(0), "Resolver cannot be zero address");
        
        Bet memory newBet = Bet({
            id: 0,
            creatorChainId: 0,
            joinerChainId: 0,
            creator: msg.sender,
            joiner: address(0),
            resolver: _resolver,
            description: description,
            stake: msg.value,
            winner: address(0),
            status: BetStatus.Open,
            expiryTimestamp: _expiryTimestamp
        });

        // If same chain, create bet directly
        if (_destinationChainId == block.chainid) {
            betCounter++;
            newBet.id = betCounter;
            newBet.creatorChainId = block.chainid;
            bets[betCounter] = newBet;
            emit BetCreated(betCounter, newBet.creator, newBet.description, newBet.stake, newBet.expiryTimestamp, newBet.resolver);
            return bytes32(0); // Return zero bytes for same-chain creation
        }

        // For cross-chain, use superchain interop
        bytes32 sendETHMsgHash = superchainETHBridge.sendETH{value: msg.value}(address(this), _destinationChainId);
        return l2ToL2CrossDomainMessenger.sendMessage(
            _destinationChainId, address(this), abi.encodeCall(this.createBetOnMainBlockchain, (sendETHMsgHash, newBet))
        );
    }

    function createBetOnMainBlockchain(bytes32 _sendETHMsgHash, Bet memory newBet) public {
        CrossDomainMessageLib.requireCrossDomainCallback();
        // CrossDomainMessageLib.requireMessageSuccess uses a special error signature that the
        // auto-relayer performs special handling on. The auto-relayer parses the _sendETHMsgHash
        // and waits for the _sendETHMsgHash to be relayed before relaying this message.
        CrossDomainMessageLib.requireMessageSuccess(_sendETHMsgHash);

        betCounter++;
        newBet.id = betCounter;
        newBet.creatorChainId = l2ToL2CrossDomainMessenger.crossDomainMessageSource();
        bets[betCounter] = newBet;

        emit BetCreated(betCounter, newBet.creator, newBet.description, newBet.stake, newBet.expiryTimestamp, newBet.resolver);
    }

    function joinBet(uint256 _destinationChainId, uint256 betId, address creator, address joiner, uint256 stake) public payable returns (bytes32) {
        require(msg.sender != creator, "Creator cannot join their own bet");
        require(msg.value == stake, "Stake must match");

        // If same chain, join bet directly
        if (_destinationChainId == block.chainid) {
            Bet storage bet = bets[betId];
            require(bet.creator != msg.sender, "Creator cannot join their own bet");
            require(bet.stake == stake, "Stake must match");
            require(bet.status == BetStatus.Open, "Bet is not open");
            require(block.timestamp < bet.expiryTimestamp, "Bet has expired");

            bet.joiner = joiner;
            bet.joinerChainId = block.chainid;
            bet.status = BetStatus.Joined;
            
            emit BetJoinedDetailed(
                betId,
                creator,
                joiner,
                stake,
                block.chainid,
                bet.status
            );
            return bytes32(0); // Return zero bytes for same-chain joining
        }

        // For cross-chain, use superchain interop
        bytes32 sendETHMsgHash = superchainETHBridge.sendETH{value: msg.value}(address(this), _destinationChainId);
        return l2ToL2CrossDomainMessenger.sendMessage(
            _destinationChainId, address(this), abi.encodeCall(this.joinBetOnMainBlockchain, (sendETHMsgHash, betId, creator, joiner, stake))
        );
    }

    function joinBetOnMainBlockchain(bytes32 _sendETHMsgHash, uint256 betId, address creator, address joiner, uint256 stake) public {
        CrossDomainMessageLib.requireCrossDomainCallback();
        CrossDomainMessageLib.requireMessageSuccess(_sendETHMsgHash);

        Bet storage bet = bets[betId];

        //require(bet.creator != creator, "Creator cannot join their own bet");
        //require(bet.stake == stake, "Stake must match");
        //require(bet.status == BetStatus.Open, "Bet is not open");

        bet.joiner = joiner;
        bet.joinerChainId = l2ToL2CrossDomainMessenger.crossDomainMessageSource();
        bet.status = BetStatus.Joined;

        emit BetJoinedDetailed(
            betId,
            creator,
            joiner,
            stake,
            l2ToL2CrossDomainMessenger.crossDomainMessageSource(),
            bet.status
        );
    }

    function checkAndHandleExpiredBet(uint256 betId) public {
        Bet storage bet = bets[betId];
        require(bet.status != BetStatus.Resolved, "Bet is already resolved");
        require(block.timestamp >= bet.expiryTimestamp, "Bet has not expired yet");

        if (bet.status == BetStatus.Open) {
            superchainETHBridge.sendETH{value: bet.stake}(bet.creator, bet.creatorChainId);
        } else if (bet.status == BetStatus.Joined) {
            uint256 halfStake = bet.stake;
            superchainETHBridge.sendETH{value: halfStake}(bet.creator, bet.creatorChainId);
            superchainETHBridge.sendETH{value: halfStake}(bet.joiner, bet.joinerChainId);
        }

        bet.status = BetStatus.Resolved;
        emit BetExpired(betId);
    }

    function isBetExpired(uint256 betId) public view returns (bool) {
        return block.timestamp >= bets[betId].expiryTimestamp;
    }

    function resolveBet(uint256 _destinationChainId, uint256 betId, address winner) public returns (bytes32) {
        // If same chain, resolve bet directly
        if (_destinationChainId == block.chainid) {
            Bet storage bet = bets[betId];
            require(bet.status == BetStatus.Joined, "Bet must be joined to resolve");
            require(winner == bet.creator || winner == bet.joiner, "Winner must be a participant");
            require(msg.sender == bet.resolver, "Only resolver can resolve the bet");

            uint256 totalStake = bet.stake * 2; // Total stake is double the individual stake

            if (winner == bet.creator) {
                if (bet.creatorChainId == block.chainid) {
                    payable(bet.creator).transfer(totalStake);
                } else {
                    superchainETHBridge.sendETH{value: totalStake}(bet.creator, bet.creatorChainId);
                }
            } else {
                if (bet.joinerChainId == block.chainid) {
                    payable(bet.joiner).transfer(totalStake);
                } else {
                    superchainETHBridge.sendETH{value: totalStake}(bet.joiner, bet.joinerChainId);
                }
            }

            bet.status = BetStatus.Resolved;
            bet.winner = winner;
            emit BetResolved(betId, winner);
            return bytes32(0); // Return zero bytes for same-chain resolution
        }

        // For cross-chain, use superchain interop
        return l2ToL2CrossDomainMessenger.sendMessage(
            _destinationChainId, 
            address(this), 
            abi.encodeCall(this.resolveBetOnMainBlockchain, (betId, winner, msg.sender))
        );
    }

    function resolveBetOnMainBlockchain(uint256 betId, address winner, address resolver) public {
        CrossDomainMessageLib.requireCrossDomainCallback();

        Bet storage bet = bets[betId];
        require(resolver == bet.resolver, "Only resolver can resolve the bet");
        require(bet.status == BetStatus.Joined, "Bet must be joined to resolve");
        require(winner == bet.creator || winner == bet.joiner, "Winner must be a participant");

        uint256 totalStake = bet.stake * 2; // Total stake is double the individual stake

        if (winner == bet.creator) {
            superchainETHBridge.sendETH{value: totalStake}(bet.creator, bet.creatorChainId);
        } else {
            superchainETHBridge.sendETH{value: totalStake}(bet.joiner, bet.joinerChainId);
        }

        bet.status = BetStatus.Resolved;
        bet.winner = winner;
        emit BetResolved(betId, winner);
    }

    // Emergency withdraw in case of stuck funds
    function emergencyWithdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    function getBetsByCreator(address creator) external view returns (Bet[] memory) {
        // First count how many bets this creator has
        uint256 count = 0;
        for (uint256 i = 1; i <= betCounter; i++) {
            if (bets[i].creator == creator) {
                count++;
            }
        }

        // Create array with exact size needed
        Bet[] memory creatorBets = new Bet[](count);
        uint256 index = 0;
        
        // Fill the array with creator's bets
        for (uint256 i = 1; i <= betCounter; i++) {
            if (bets[i].creator == creator) {
                creatorBets[index] = bets[i];
                index++;
            }
        }
        
        return creatorBets;
    }

    function getBetsByJoiner(address joiner) external view returns (Bet[] memory) {
        // First count how many bets this joiner has joined
        uint256 count = 0;
        for (uint256 i = 1; i <= betCounter; i++) {
            if (bets[i].joiner == joiner) {
                count++;
            }
        }

        // Create array with exact size needed
        Bet[] memory joinerBets = new Bet[](count);
        uint256 index = 0;
        
        // Fill the array with joiner's bets
        for (uint256 i = 1; i <= betCounter; i++) {
            if (bets[i].joiner == joiner) {
                joinerBets[index] = bets[i];
                index++;
            }
        }
        
        return joinerBets;
    }

    function getActiveBets() external view returns (Bet[] memory) {
        // First count how many active bets exist
        uint256 count = 0;
        for (uint256 i = 1; i <= betCounter; i++) {
            if (bets[i].status != BetStatus.Resolved) {
                count++;
            }
        }

        // Create array with exact size needed
        Bet[] memory activeBets = new Bet[](count);
        uint256 index = 0;
        
        // Fill the array with active bets
        for (uint256 i = 1; i <= betCounter; i++) {
            if (bets[i].status != BetStatus.Resolved) {
                activeBets[index] = bets[i];
                index++;
            }
        }
        
        return activeBets;
    }

    function getAllUserBets(address user) external view returns (Bet[] memory) {
        // First count how many active bets this user has
        uint256 count = 0;
        for (uint256 i = 1; i <= betCounter; i++) {
            if ((bets[i].creator == user || bets[i].joiner == user || bets[i].resolver == user)) {
                count++;
            }
        }

        // Create array with exact size needed
        Bet[] memory userBets = new Bet[](count);
        uint256 index = 0;
        

        for (uint256 i = 1; i <= betCounter; i++) {
            if ((bets[i].creator == user || bets[i].joiner == user || bets[i].resolver == user)) {
                userBets[index] = bets[i];
                index++;
            }
        }
        
        return userBets;
    }

    // Function to get resolver of a bet
    function getBetResolver(uint256 betId) public view returns (address) {
        return bets[betId].resolver;
    }

}
