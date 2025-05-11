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
        string description;
        uint256 stake;
        address winner;
        BetStatus status;
    }

    mapping(uint256 => Bet) public bets;

    event BetCreated(uint256 indexed id, address indexed creator, string description, uint256 stake);
    event BetJoined(uint256 indexed id, address indexed joiner);
    event BetResolved(uint256 indexed id, address indexed winner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the contract owner");
        _;
    }

    modifier onlyOpen(uint256 betId) {
        require(bets[betId].status == BetStatus.Open, "Bet is not open");
        _;
    }

    modifier onlyJoined(uint256 betId) {
        require(bets[betId].status == BetStatus.Joined, "Bet not yet joined");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function createBet(uint256 _destinationChainId, string memory description) public payable returns (bytes32)  {
        require(msg.value > 0, "Must send some ETH to stake");
        Bet memory newBet = Bet({
            id: 0,
            creatorChainId: 0,
            joinerChainId: 0,
            creator: msg.sender,
            joiner: address(0),
            description: description,
            stake: msg.value,
            winner: address(0),
            status: BetStatus.Open
        });

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

        emit BetCreated(betCounter, newBet.creator, newBet.description, newBet.stake);
    }

    function joinBet(uint256 _destinationChainId, uint256 betId, address creator, address joiner, uint256 stake) public payable returns (bytes32) {
        require(msg.sender != creator, "Creator cannot join their own bet");
        require(msg.value == stake, "Stake must match");

        bytes32 sendETHMsgHash = superchainETHBridge.sendETH{value: msg.value}(address(this), _destinationChainId);

        return l2ToL2CrossDomainMessenger.sendMessage(
            _destinationChainId, address(this), abi.encodeCall(this.joinBetOnMainBlockchain, (sendETHMsgHash, betId, creator, joiner, stake))
        );
    }


    function joinBetOnMainBlockchain(bytes32 _sendETHMsgHash, uint256 betId, address creator, address joiner, uint256 stake) public {
        CrossDomainMessageLib.requireCrossDomainCallback();
        // CrossDomainMessageLib.requireMessageSuccess uses a special error signature that the
        // auto-relayer performs special handling on. The auto-relayer parses the _sendETHMsgHash
        // and waits for the _sendETHMsgHash to be relayed before relaying this message.
        CrossDomainMessageLib.requireMessageSuccess(_sendETHMsgHash);

        Bet storage bet = bets[betId];

        require(bet.creator != creator, "Creator cannot join their own bet");
        require(bet.stake == stake, "Stake must match");
        require(bet.status == BetStatus.Open, "Bet is not open");

        bet.joiner = joiner;
        bet.joinerChainId = l2ToL2CrossDomainMessenger.crossDomainMessageSource();
        bet.status = BetStatus.Joined;

        emit BetJoined(betId, msg.sender);
    }



    /*
    function resolveBetOnMainBlockchain(bytes32 _sendETHMsgHash, uint256 betId, address winner) public {
        CrossDomainMessageLib.requireCrossDomainCallback();
        CrossDomainMessageLib.requireMessageSuccess(_sendETHMsgHash);

        Bet storage bet = bets[betId];
        require(winner == bet.creator || winner == bet.joiner, "Winner must be a participant");
        uint256 totalStake = bet.stake * 2;

        if (winner == bet.creator) {
            superchainETHBridge.sendETH{value: totalStake}(bet.creator, bet.creatorChainId);
        }
        else {
            superchainETHBridge.sendETH{value: totalStake}(bet.joiner, bet.joinerChainId);
        }

        emit BetResolved(betId, winner);
    }
    */




    // Emergency withdraw in case of stuck funds
    function emergencyWithdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }
}
