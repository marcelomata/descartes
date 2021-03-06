// Copyright (C) 2020 Cartesi Pte. Ltd.

// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.

// This program is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
// PARTICULAR PURPOSE. See the GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Note: This component currently has dependencies that are licensed under the GNU
// GPL, version 3, and so you should treat this component as a whole as being under
// the GPL version 3. But all Cartesi-written code in this component is licensed
// under the Apache License, version 2, or a compatible permissive license, and can
// be used independently under the Apache v2 license. After this component is
// rewritten, the entire component will be released under the Apache v2 license.

/// @title Descartes
/// @author Stephen Chen
pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

import "@cartesi/util/contracts/Merkle.sol";
import "@cartesi/util/contracts/Decorated.sol";
import "@cartesi/logger/contracts/LoggerInterface.sol";
import "@cartesi/arbitration/contracts/VGInterface.sol";
import "./DescartesInterface.sol";


contract Descartes is Decorated, DescartesInterface {
    address machine; // machine which will run the challenge
    LoggerInterface li;
    VGInterface vg;

    struct DescartesCtx {
        uint256 pendingDrivesPointer; // the pointer to the current pending drive
        uint256 finalTime; // max number of machine cycle to run
        uint64 outputPosition; // memory position of machine output
        uint256 roundDuration; // time interval to interact with this contract
        uint256 timeOfLastMove; // last time someone made a move with deadline
        uint256 vgInstance;
        bytes32 templateHash; // pristine hash of machine
        bytes32 initialHash; // initial hash with all drives mounted
        bytes32 claimedFinalHash; // claimed final hash of the machine
        bytes32 claimedOutput; // claimed final machine output
        address claimer; // responsible for claiming the machine output
        address challenger; // user can challenge claimer's output
        State currentState;
        uint256[] pendingDrives; // indices of the pending drives
        bytes32[] driveHash; // root hash of the drives
        Drive[] inputDrives;
    }

    mapping(uint256 => DescartesCtx) internal instance;

    // These are the possible states and transitions of the contract.

    // +---+
    // |   |
    // +---+
    //   |
    //   | instantiate
    //   v
    // +------------------+    abortByDeadline    +------------------------+
    // | WaitingProviders |---------------------->| ProviderMissedDeadline |
    // +------------------+                       +------------------------+
    //   |
    //   | claimLoggerDrive
    //   | or
    //   | claimDirectDrive
    //   v
    // +--------------+   abortByDeadline    +-----------------------+
    // | WaitingClaim |--------------------->| ClaimerMissedDeadline |
    // +--------------+                      +-----------------------+
    //   |
    //   |
    //   |
    //   | submitClaim
    //   v
    // +---------------------+  confirm    +-----------------+
    // | WaitingConfirmation |------------>| ConsensusResult |
    // +---------------------+ or deadline +-----------------+
    //   |
    //   |
    //   | challenge
    //   v
    // +------------------+    winByVG     +------------+
    // | WaitingChallenge |--------------->| ClaimerWon |
    // +------------------+                +------------+
    //   |
    //   |
    //   |                  winByVG        +---------------+
    //   +-------------------------------->| ChallengerWon |
    //                                     +---------------+
    //

    event DescartesCreated(
        uint256 _index
    );
    event ClaimSubmitted(uint256 _index, bytes32 _claimedFinalHash);
    event ResultConfirmed(uint256 _index);
    event ChallengeStarted(uint256 _index);
    event DescartesFinished(uint256 _index, uint8 _state);

    constructor(
        address _liAddress,
        address _vgAddress,
        address _machineAddress) public
    {
        machine = _machineAddress;
        vg = VGInterface(_vgAddress);
        li = LoggerInterface(_liAddress);
    }

    /// @notice Instantiate a Descartes SDK instance.
    /// @param _finalTime max cycle of the machine for that computation
    /// @param _templateHash hash of the machine with all drives empty
    /// @param _outputPosition position of the output drive
    /// @param _roundDuration duration of the round (security param)
    /// @param _inputDrives an array of drive which assemble the machine
    /// @return uint256, Descartes index
    function instantiate(
        uint256 _finalTime,
        bytes32 _templateHash,
        uint64 _outputPosition,
        uint256 _roundDuration,
        address _claimer,
        address _challenger,
        Drive[] memory _inputDrives) public returns (uint256)
    {
        DescartesCtx storage i = instance[currentIndex];

        require(_challenger != _claimer, "Claimer cannot be a challenger");

        State currentState = State.WaitingClaim;
        uint256 drivesLength = _inputDrives.length;
        i.driveHash = new bytes32[](drivesLength);
        for (uint256 j = 0; j < drivesLength; j++) {
            Drive memory drive = _inputDrives[j];

            if (!drive.needsLogger && !drive.needsProvider) {
                drive.loggerLog2Size = 5;
                bytes32[] memory data = getWordHashesFromBytes32(drive.directValueOrLoggerRoot);
                i.driveHash[j] = Merkle.calculateRootFromPowerOfTwo(data);
            } else if (drive.needsLogger) {
                if (li.isLogAvailable(drive.directValueOrLoggerRoot, drive.loggerLog2Size)) {
                    i.driveHash[j] = drive.directValueOrLoggerRoot;
                } else {
                    i.driveHash[j] = bytes32(0);
                    currentState = State.WaitingProviders;
                    i.pendingDrives.push(j);
                }
            } else if (drive.needsProvider) {
                i.driveHash[j] = bytes32(0);
                currentState = State.WaitingProviders;
                i.pendingDrives.push(j);
            }
            i.inputDrives.push(Drive(
                drive.position,
                drive.loggerLog2Size,
                drive.directValueOrLoggerRoot,
                drive.provider,
                drive.needsProvider,
                drive.needsLogger
            ));
        }

        i.challenger = _challenger;
        i.claimer = _claimer;
        i.finalTime = _finalTime;
        i.templateHash = _templateHash;
        i.initialHash = _templateHash;
        i.outputPosition = _outputPosition;
        i.roundDuration = _roundDuration;
        i.timeOfLastMove = now;
        i.currentState = currentState;

        emit DescartesCreated(
            currentIndex
        );
        active[currentIndex] = true;
        return currentIndex++;
    }

    /// @notice Challenger accepts claim.
    /// @param _index index of Descartes instance that the challenger is confirming the claim.
    function confirm(uint256 _index) public
        onlyInstantiated(_index)
        onlyBy(instance[_index].challenger)
        increasesNonce(_index)
    {
        DescartesCtx storage i = instance[_index];
        require(i.currentState == State.WaitingConfirmation, "State should be WaitingConfirmation");

        i.currentState = State.ConsensusResult;
        emit ResultConfirmed(_index);
    }

    /// @notice Challenger disputes the claim, starting a verification game.
    /// @param _index index of Descartes instance which challenger is starting the VG.
    function challenge(uint256 _index) public
        onlyInstantiated(_index)
        onlyBy(instance[_index].challenger)
        increasesNonce(_index)
    {
        DescartesCtx storage i = instance[_index];
        require(i.currentState == State.WaitingConfirmation, "State should be WaitingConfirmation");

        i.vgInstance = vg.instantiate(
            i.challenger,
            i.claimer,
            i.roundDuration,
            machine,
            i.initialHash,
            i.claimedFinalHash,
            i.finalTime);
        i.currentState = State.WaitingChallenge;

        emit ChallengeStarted(_index);
    }

    /// @notice Claimer claims the machine final hash and also validate the drives and initial hash of the machine.
    /// @param _inputDrives are an array of ready drives, containing siblings of the drive which contains the prior drives in the order
    /// @dev Example: consider 3 drives, the first drive's siblings should be a pristine machine.
    ///      The second drive's siblings should be the machine with drive 1 mounted.
    ///      The third drive's siblings should be the machine with drive 2 mounted.
    function submitClaim(
        uint256 _index,
        bytes32 _claimedFinalHash,
        Drive[] memory _inputDrives,
        bytes32[][] memory _drivesSiblings,
        bytes32 _output,
        bytes32[] memory _outputSiblings) public
        onlyInstantiated(_index)
        onlyBy(instance[_index].claimer)
        increasesNonce(_index)
    {
        DescartesCtx storage i = instance[_index];
        require(i.currentState == State.WaitingClaim, "State should be WaitingClaim");
        require(_inputDrives.length == i.inputDrives.length, "Claimed drive number should match stored drive number");
        require(_inputDrives.length == _drivesSiblings.length, "Claimed drive number should match claimed siblings number");

        bytes32[] memory data = getWordHashesFromBytes32(_output);

        require(
            Merkle.getRootWithDrive(
                i.outputPosition,
                5,
                Merkle.calculateRootFromPowerOfTwo(data),
                _outputSiblings) == _claimedFinalHash,
            "Output is not contained in the final hash");

        uint256 drivesLength = _inputDrives.length;
        for (uint256 j = 0; j < drivesLength; j++) {
            require(_inputDrives[j].position == i.inputDrives[j].position, "Drive position doesn't match");
            require(_inputDrives[j].loggerLog2Size == i.inputDrives[j].loggerLog2Size, "Drive log2 size doesn't match");
            require(
                Merkle.getRootWithDrive(
                    _inputDrives[j].position,
                    _inputDrives[j].loggerLog2Size,
                    Merkle.getPristineHash(uint8(_inputDrives[j].loggerLog2Size)),
                    _drivesSiblings[j]) == i.initialHash,
                "Drive siblings must be compatible with previous initial hash for empty drive");
            i.initialHash = Merkle.getRootWithDrive(
                _inputDrives[j].position,
                _inputDrives[j].loggerLog2Size,
                i.driveHash[j],
                _drivesSiblings[j]);
        }

        i.claimedFinalHash = _claimedFinalHash;
        i.currentState = State.WaitingConfirmation;
        i.claimedOutput = _output;

        emit ClaimSubmitted(_index, _claimedFinalHash);
    }

    /// @notice Is the given user concern about this instance.
    function isConcerned(uint256 _index, address _user) public view
        onlyInstantiated(_index)
        returns (bool)
    {
        DescartesCtx memory i = instance[_index];
        return (_user == i.claimer || _user == i.challenger);
    }

    /// @notice Get state of the instance concerning given user.
    function getState(uint256 _index, address) public view
        onlyInstantiated(_index)
        returns (
            uint256[] memory,
            address[] memory,
            bytes32[] memory,
            Drive[] memory
        )
    {
        uint256[] memory uintValues = new uint256[](3);
        uintValues[0] = instance[_index].finalTime;
        uintValues[1] = instance[_index].timeOfLastMove + getMaxStateDuration(
            _index);
        uintValues[2] = instance[_index].outputPosition;

        address[] memory addressValues = new address[](2);
        addressValues[0] = instance[_index].challenger;
        addressValues[1] = instance[_index].claimer;

        bytes32[] memory bytesValues = new bytes32[](4);
        bytesValues[0] = instance[_index].initialHash;
        bytesValues[1] = instance[_index].claimedFinalHash;
        bytesValues[2] = instance[_index].claimedOutput;
        bytesValues[3] = getCurrentState(_index);

        if (instance[_index].currentState == State.WaitingProviders ||
            instance[_index].currentState == State.ProviderMissedDeadline) {
            Drive[] memory drives = new Drive[](1);
            drives[0] = instance[_index].inputDrives[instance[_index].pendingDrivesPointer];
            return (
                uintValues,
                addressValues,
                bytesValues,
                drives);
        } else {
            return (
                uintValues,
                addressValues,
                bytesValues,
                instance[_index].inputDrives);
        }
    }

    function getCurrentState(uint256 _index) public view
        onlyInstantiated(_index)
        returns (bytes32)
    {
        State currentState = instance[_index].currentState;
        if (currentState == State.WaitingProviders) {
            return "WaitingProviders";
        }
        if (currentState == State.ClaimerMissedDeadline) {
            return "ClaimerMissedDeadline";
        }
        if (currentState == State.ProviderMissedDeadline) {
            return "ProviderMissedDeadline";
        }
        if (currentState == State.WaitingClaim) {
            return "WaitingClaim";
        }
        if (currentState == State.WaitingConfirmation) {
            return "WaitingConfirmation";
        }
        if (currentState == State.WaitingChallenge) {
            return "WaitingChallenge";
        }
        if (currentState == State.ConsensusResult) {
            return "ConsensusResult";
        }

        revert("Unrecognized state");
    }

    /// @notice Get sub-instances of the instance.
    function getSubInstances(uint256 _index, address) public view
        onlyInstantiated(_index)
        returns (address[] memory _addresses, uint256[] memory _indices)
    {
        address[] memory a;
        uint256[] memory i;

        if (instance[_index].currentState == State.WaitingChallenge) {
            a = new address[](1);
            i = new uint256[](1);
            a[0] = address(vg);
            i[0] = instance[_index].vgInstance;
        } else {
            a = new address[](0);
            i = new uint256[](0);
        }
        return (a, i);
    }

    /// @notice Claim the content of a direct drive (only drive provider can call it).
    /// @param _index index of Descartes instance the drive belongs to.
    /// @param _value bytes32 value of the direct drive
    function claimDirectDrive(uint256 _index, bytes32 _value) public
        onlyInstantiated(_index)
        requirementsForClaimDrive(_index)
    {
        DescartesCtx storage i = instance[_index];
        uint256 driveIndex = i.pendingDrives[i.pendingDrivesPointer];
        Drive storage drive = i.inputDrives[driveIndex];

        require(drive.needsProvider && !drive.needsLogger, "Invalid drive to claim for direct value");

        bytes32[] memory data = getWordHashesFromBytes32(_value);
        bytes32 driveHash = Merkle.calculateRootFromPowerOfTwo(data);

        drive.loggerLog2Size = 5;
        i.driveHash[driveIndex] = driveHash;
        i.pendingDrivesPointer++;
        i.timeOfLastMove = now;

        if (i.pendingDrivesPointer == i.pendingDrives.length) {
            i.currentState = State.WaitingClaim;
        }
    }

    /// @notice Claim the hash of a logger drive (only drive provider can call it);
    ///         Or claim that the content is available on logger with given hash.
    /// @param _index index of Descartes instance the drive belongs to
    /// @param _root root hash of the logger drive
    function claimLoggerDrive(uint256 _index, bytes32 _root) public
        onlyInstantiated(_index)
        requirementsForClaimDrive(_index)
     {
        DescartesCtx storage i = instance[_index];
        uint256 driveIndex = i.pendingDrives[i.pendingDrivesPointer];
        Drive storage drive = i.inputDrives[driveIndex];

        require(drive.needsLogger, "Invalid drive to claim for logger");

        if (drive.needsProvider) {
            drive.directValueOrLoggerRoot = _root;
            drive.needsProvider = false;
        }

        require(drive.directValueOrLoggerRoot == _root, "Hash value doesn't match drive hash");
        require(li.isLogAvailable(drive.directValueOrLoggerRoot, drive.loggerLog2Size), "Hash is not available on logger yet");

        i.driveHash[driveIndex] = drive.directValueOrLoggerRoot;
        i.pendingDrivesPointer++;
        i.timeOfLastMove = now;

        if (i.pendingDrivesPointer == i.pendingDrives.length) {
            i.currentState = State.WaitingClaim;
        }
    }

    /// @notice In case one of the parties wins the verification game,
    ///         then he or she can call this function to claim victory in
    ///         this contract as well.
    /// @param _index index of Descartes instance to win
    function winByVG(uint256 _index) public
        onlyInstantiated(_index)
        increasesNonce(_index)
    {
        DescartesCtx storage i = instance[_index];
        require(i.currentState == State.WaitingChallenge, "State is not WaitingChallenge, cannot winByVG");
        uint256 vgIndex = i.vgInstance;

        if (vg.stateIsFinishedChallengerWon(vgIndex)) {
            i.currentState = State.ChallengerWon;
            return;
        }

        if (vg.stateIsFinishedClaimerWon(vgIndex)) {
            i.currentState = State.ClaimerWon;
            return;
        }
        require(false, "State of VG is not final");
    }

    /// @notice Abort the instance by missing deadline.
    /// @param _index index of Descartes instance to abort
    function abortByDeadline(uint256 _index) public onlyInstantiated(_index) {
        DescartesCtx storage i = instance[_index];
        bool afterDeadline = (now > i.timeOfLastMove + getMaxStateDuration(
            _index)
        );

        require(afterDeadline, "Deadline is not over for this specific state");

        if (i.currentState == State.WaitingProviders) {
            i.currentState = State.ProviderMissedDeadline;
            return;
        }
        if (i.currentState == State.WaitingClaim) {
            i.currentState = State.ClaimerMissedDeadline;
            return;
        }

        revert("Cannot abort current state");
    }

    /// @notice Get result of a finished instance.
    /// @param _index index of Descartes instance to get result
    /// @return bool, indicates the result is ready
    /// @return bool, indicates the sdk is still running
    /// @return address, the user to blame for the abnormal stop of the sdk
    /// @return bytes32, the result of the sdk if available
    function getResult(uint256 _index) public view
        onlyInstantiated(_index)
        returns (bool, bool, address, bytes32)
    {
        DescartesCtx memory i = instance[_index];
        if (i.currentState == State.ConsensusResult) {
            return (true, false, address(0), i.claimedOutput);
        }
        if (i.currentState == State.WaitingProviders ||
            i.currentState == State.WaitingClaim ||
            i.currentState == State.WaitingConfirmation ||
            i.currentState == State.WaitingChallenge) {
            return (false, true, address(0), bytes32(0));
        }
        if (i.currentState == State.ProviderMissedDeadline) {
            return (false, false, i.inputDrives[i.pendingDrivesPointer].provider, bytes32(0));
        }
        if (i.currentState == State.ClaimerMissedDeadline ||
            i.currentState == State.ChallengerWon) {
            return (false, false, i.claimer, bytes32(0));
        }
        if (i.currentState == State.ClaimerWon) {
            return (false, false, i.challenger, bytes32(0));
        }

        revert("Unrecognized state");
    }

    /// @notice Convert bytes32 into bytes8[] and calculate the hashes of them
    function getWordHashesFromBytes32(bytes32 _value) private pure returns(bytes32[] memory) {
        bytes32[] memory data = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            bytes8 dataBytes8 = bytes8(_value << (i * 64) & 0xffffffffffffffff000000000000000000000000000000000000000000000000);
            data[i] = keccak256(abi.encodePacked(dataBytes8));
        }
        return data;
    }

    /// @notice Get the worst case scenario duration for a specific state
    function getMaxStateDuration(
        uint256 _index
    ) private view returns (uint256)
    {
        uint256 partitionSize = 1;
        uint256 picoSecondsToRunInsn = 500; // 500 pico seconds to run a instruction
        uint256 timeToStartMachine = 40; // 40 seconds to start the machine for the first time
        if (instance[_index].currentState == State.WaitingProviders) {
            // time to upload to logger + assemble pristine machine with drive
            uint256 maxLoggerUploadTime = 40 * 60;
            return timeToStartMachine +
                maxLoggerUploadTime +
                instance[_index].roundDuration;
        }

        if (instance[_index].currentState == State.WaitingClaim) {
            // time to run entire machine + time to react
            return timeToStartMachine +
                ((instance[_index].finalTime * picoSecondsToRunInsn) / 1e12) +
                instance[_index].roundDuration;
        }

        if (instance[_index].currentState == State.WaitingConfirmation) {
            // time to run entire machine + time to react
            return timeToStartMachine +
                ((instance[_index].finalTime * picoSecondsToRunInsn) / 1e12) +
                instance[_index].roundDuration;
        }

        if (instance[_index].currentState == State.WaitingChallenge) {
            // time to run a verification game + time to react
            return vg.getMaxInstanceDuration(
                instance[_index].roundDuration,
                timeToStartMachine,
                partitionSize,
                instance[_index].finalTime,
                picoSecondsToRunInsn) + instance[_index].roundDuration;
        }

        if (instance[_index].currentState == State.ClaimerWon ||
            instance[_index].currentState == State.ChallengerWon ||
            instance[_index].currentState == State.ClaimerMissedDeadline ||
            instance[_index].currentState == State.ConsensusResult) {
            return 0; // final state
        }
    }

    /// @notice several require statements for a drive
    modifier requirementsForClaimDrive(uint256 _index) {
        DescartesCtx storage i = instance[_index];
        require(i.currentState == State.WaitingProviders, "The state is not WaitingProviders");
        require(i.pendingDrivesPointer < i.pendingDrives.length, "No available pending drives");

        uint256 driveIndex = i.pendingDrives[i.pendingDrivesPointer];
        require(driveIndex < i.inputDrives.length, "Invalid drive index");

        Drive memory drive = i.inputDrives[driveIndex];
        require(i.driveHash[driveIndex] == bytes32(0), "The drive hash shouldn't be filled");
        require(drive.provider == msg.sender, "The sender is not provider");

        _;
    }
}

