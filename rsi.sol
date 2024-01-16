// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// RSIContract inherits from Ownable, meaning it has access control functionality.
contract RSIContract is Ownable {
    using SafeMath for uint256;

    // Public variable representing the ERC20 token for USDC.
    IERC20 public usdcToken; // Assuming USDC is ERC20 compliant

    // Mapping to track USDC balances of users.
    mapping(address => uint256) public usdcBalances;
    // Mapping to track RSI balances of users.
    mapping(address => uint256) public rsiBalances;
    // Mapping to track the total USDC received by each user from sendUSDC function.
    mapping(address => uint256) public totalUsdcReceived;
    // Mapping to track auto compound setting for each user.
    mapping(address => bool) public autoCompoundEnabled;

    // Variables to keep track of total USDC deposited, withdrawn, and returned during burn.
    uint256 public totalUsdcDeposited;
    uint256 public totalUsdcWithdrawn;
    uint256 public totalUsdcReturnedDuringBurn;
    uint256 public totalUSDCBalance; 
    uint256 public allUSDCReceived;
    uint256 public totalRSIBurnt;
    uint256 public totalRSIMinted;

    // Structure to represent a burn request with user address and RSI amount.
    struct BurnRequest {
        address user;
        uint256 amount;
    }

    // Public array to store burn requests.
    BurnRequest[] public burnQueue;

    // Reentrancy guard variable
    bool private y;

    // Events to log various contract actions for external monitoring.
    event DepositMint(address indexed user, uint256 amount);
    event OwnerWithdrawal(uint256 amount);
    event OwnerDeposit(address indexed owner, uint256 amount); // New event for ownerDeposit
    event RSIburnInitiated(address indexed user, uint256 amount, uint256 usdcReturned);
    event BurnProcessComplete(address indexed user, uint256 amount, uint256 usdcReturned);
    event SendUSDC(address indexed sender, uint256 amount); // New event for sendUSDC

    // Modifier to prevent reentrancy
    modifier nonReentrant() {
        require(!y, "Reentrant call");
        y = true;
        _;
        y = false;
    }

    // Constructor to initialize the contract with the address of the USDC token.
    constructor(address _usdcToken, address _owner) Ownable(_owner) {
        usdcToken = IERC20(_usdcToken);
    }
    
    // Amount output converter function.
    function a(uint256 amount) internal pure returns (uint256) {
        return amount / (10**18);
    }

    // Amount input converter function.
    function b(uint256 amount) internal pure returns (uint256) {
        return amount * (10**18);
    }

    // External function allowing users to deposit USDC into the contract.
    function deposit(uint256 amount) external nonReentrant {
        // Convert from user friendly amount.
        amount = b(amount);
        // Transfer USDC from the user to the contract.
        require(usdcToken.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
        // Update user's USDC balance and total deposited amount.
        usdcBalances[msg.sender] = usdcBalances[msg.sender].add(amount);
        // Update totalUsdcDeposited.
        totalUsdcDeposited = totalUsdcDeposited.add(amount);
        // Update the total USDC Balance.
        totalUSDCBalance = totalUsdcDeposited.sub(totalUsdcWithdrawn);
        // Mint 1 RSI for every 1 USDC deposited.
        rsiBalances[msg.sender] = rsiBalances[msg.sender].add(amount);
        // Update Total RSI Minted All Time
        totalRSIMinted = totalRSIMinted.add(amount);
        // Emit Deposit event for external monitoring.
        emit DepositMint(msg.sender, amount);
    }

    // External function allowing the owner to withdraw USDC from the contract.
    function ownerWithdrawal(uint256 amount) external onlyOwner nonReentrant {
        // Convert from user friendly amount.
        amount = b(amount);
        // Calculate the total USDC Balance.
        totalUSDCBalance = totalUsdcDeposited.sub(totalUsdcWithdrawn);
        // Check if the requested withdrawal amount is within the available fund balance.
        require(amount <= totalUSDCBalance, "Withdrawal amount greater than available fund balance");
        // Transfer USDC from the contract to the owner.
        require(usdcToken.transfer(owner(), amount), "USDC transfer to owner failed");
        // Update total withdrawn amount.
        totalUsdcWithdrawn = totalUsdcWithdrawn.add(amount);
        // Emit OwnerWithdrawal event for external monitoring.
        emit OwnerWithdrawal(amount);
    }

    // External function allowing the owner to deposit USDC into the contract.
    function ownerDeposit(uint256 amount) external onlyOwner nonReentrant {
        // Convert from user friendly amount.
        amount = b(amount);
        // Transfer USDC from the owner to the contract.
        require(usdcToken.transferFrom(owner(), address(this), amount), "Owner USDC transfer failed");
        // Update total deposited amount.
        totalUsdcDeposited = totalUsdcDeposited.add(amount);
        // Calculate the total USDC Balance.
        totalUSDCBalance = totalUsdcDeposited.sub(totalUsdcWithdrawn);
        // Emit OwnerDeposit event for external monitoring.
        emit OwnerDeposit(owner(), amount);
        // Process the burn queue immediately after adding a new request.
        processBurnQueue();
    }

    // Function to allow users to set their auto compound setting.
    function setAutoCompound(bool isEnabled) external {
        autoCompoundEnabled[msg.sender] = isEnabled;
    }

    // External function allowing users to send USDC to other users based on their RSI balances.
    function sendUSDC(uint256 amount) external nonReentrant {
        // Convert from user friendly amount.
        amount = b(amount);
        // Check if the requested amount is greater than zero.
        require(amount > 0, "Amount must be greater than 0");
        // Calculate the total RSI across all users.
        uint256 totalRSI = calculateTotalRSI();

        // Iterate through all users and transfer the corresponding amount of USDC.
        address[] memory users = getUsersWithPositiveRSI();
        for (uint256 i = 0; i < users.length; i++) {
            // Define user share of RSI.
            uint256 userShareRSI = (rsiBalances[users[i]]).div(totalRSI);
            // Define amount to send to user.
            uint256 usdcToTransfer = userShareRSI.mul(amount);

            // If auto compound is enabled, initiate deposit for the user.
            if (autoCompoundEnabled[users[i]]) {
                depositForUser(users[i], usdcToTransfer);
            } else {
                // Otherwise, send USDC to the user's wallet.
                require(usdcToken.transfer(users[i], usdcToTransfer), "USDC transfer to user failed");
            }

            // Update the totalUsdcReceived for each user.
            totalUsdcReceived[users[i]] = totalUsdcReceived[users[i]].add(usdcToTransfer);
            // Update the USDC received for everyone over the course of RSI's history.
            allUSDCReceived = allUSDCReceived.add(usdcToTransfer);
        }

        // Emit SendUSDC event for external monitoring.
        emit SendUSDC(msg.sender, amount);
    }

    // Internal function to initiate compounding deposit for a specific user.
    function depositForUser(address user, uint256 amount) internal {
        // Convert from user friendly amount.
        amount = b(amount);
        // Transfer USDC from the user to the contract.
        require(usdcToken.transferFrom(user, address(this), amount), "USDC transfer failed");
        // Update user's USDC balance and total deposited amount.
        usdcBalances[user] = usdcBalances[user].add(amount);
        // Update totalUsdcDeposited.
        totalUsdcDeposited = totalUsdcDeposited.add(amount);
        // Update the total USDC Balance.
        totalUSDCBalance = totalUsdcDeposited.sub(totalUsdcWithdrawn);
        // Mint 1 RSI for every 1 USDC deposited.
        rsiBalances[user] = rsiBalances[user].add(amount);
        // Update Total RSI Minted All Time
        totalRSIMinted = totalRSIMinted.add(amount);
        // Emit Deposit event for external monitoring.
        emit DepositMint(user, amount);
    }

    // External function allowing users to initiate the burning of their RSI tokens.
    function burnRSI(uint256 amount) external nonReentrant {
        // Convert from user friendly amount.
        amount = b(amount);
        // Check if the user has sufficient RSI balance to burn.
        require(rsiBalances[msg.sender] >= amount, "Insufficient RSI balance");
        // Update user's RSI balance to reflect burn.
        rsiBalances[msg.sender] = rsiBalances[msg.sender].sub(amount);
        // Totals RSI burnt over time. 
        totalRSIBurnt = totalRSIBurnt.add(amount);
        // Add the burn request to the burn queue.
        burnQueue.push(BurnRequest(msg.sender, amount));
        // Emit RSIburned event for external monitoring.
        emit RSIburnInitiated(msg.sender, amount, 0);
        // Process the burn queue immediately after adding a new request.
        processBurnQueue();
    }

    // Internal function to process the burn queue and return USDC to users.
    function processBurnQueue() internal nonReentrant {
        // Process the burn queue when there are sufficient funds.
        while (burnQueue.length > 0) {
            BurnRequest memory request = burnQueue[0];
            // Calculate the user's share of USDC based on the updated formula.
            uint256 userShareUSDC = (usdcBalances[request.user]);
            // Check if there are sufficient funds to process the request.
            if (userShareUSDC >= request.amount && userShareUSDC <= usdcToken.balanceOf(address(this))) {
                // Transfer USDC to the user based on their RSI amount.
                require(usdcToken.transfer(request.user, request.amount), "USDC transfer to user failed");
                // Subtract 'request.amount' from the user's USDC balance.
                usdcBalances[request.user] = usdcBalances[request.user].sub(request.amount);
                // Update total withdrawn amount.
                totalUsdcWithdrawn = totalUsdcWithdrawn.add(request.amount);
                // Update the totalUsdcReturnedDuringBurn.
                totalUsdcReturnedDuringBurn = totalUsdcReturnedDuringBurn.add(request.amount);
                // Remove the processed request from the queue.
                for (uint256 i = 0; i < burnQueue.length - 1; i++) {
                    burnQueue[i] = burnQueue[i + 1];
                }
                burnQueue.pop();
                // Emit BurnProcessComplete event for external monitoring.
                emit BurnProcessComplete(request.user, request.amount, userShareUSDC);
            } else {
                // Exit the loop if there are insufficient funds to process the remaining requests.
                break;
            }
        }
    }

    // Internal function to calculate the total circulating RSI.
    function calculateTotalRSI() internal view returns (uint256) {
        uint256 totalCirculatingRSI = 0;

        // Iterate through all users and sum their RSI balances.
        address[] memory users = getUsersWithPositiveRSI();
        for (uint256 i = 0; i < users.length; i++) {
            totalCirculatingRSI = totalCirculatingRSI.add(rsiBalances[users[i]]);
        }

        return totalCirculatingRSI;
    }

    // Internal function to get all users.
    function getUsers() internal view returns (address[] memory) {
        address[] memory users = new address[](burnQueue.length);
        for (uint256 i = 0; i < burnQueue.length; i++) {
            users[i] = burnQueue[i].user;
        }
        return users;
    }

    // Internal function to get all users with positive RSI balances.
    function getUsersWithPositiveRSI() internal view returns (address[] memory) {
        uint256 userCount = 0;

        // Get all users.
        address[] memory allUsers = getUsers();

        // Iterate through all users and count those with positive RSI balances.
        for (uint256 i = 0; i < allUsers.length; i++) {
            if (rsiBalances[allUsers[i]] > 0) {
                userCount = userCount.add(1);
            }
        }

        // Initialize array and index variables.
        address[] memory users = new address[](userCount);
        uint256 currentIndex = 0;

        // Iterate through all users and include those with positive RSI balances in the array.
        for (uint256 i = 0; i < allUsers.length; i++) {
            if (rsiBalances[allUsers[i]] > 0) {
                users[currentIndex] = allUsers[i];
                currentIndex = currentIndex.add(1);
            }
        }

        return users;
    }

    // View total RSI balance.
    function allRSIBalanceTVL() external view returns (uint256) {
        return a(calculateTotalRSI());
    }
    
    // External function to view USDC Balance.
    function allUSDCBalance() external view returns (uint256) {
        return a(totalUSDCBalance);
    }

    // External function to view all USDC profits sent to users.
    function allUSDCSent() external view returns (uint256) {
        return a(allUSDCReceived);
    }

    // External function to view all RSI minted over time.
    function allRSIMinted() external view returns (uint256) {
        return a(totalRSIMinted);
    }

    // External function to view all RSI burnt over time.
    function allRSIBurnt() external view returns (uint256) {
        return a(totalRSIBurnt);
    }

    // External function to view count of users with positive RSI balance.
    function CountUsersWithPositiveRSICount() external view returns (uint256) {
        uint256 userCount = 0;

        // Get all users.
        address[] memory allUsers = getUsers();

        // Iterate through all users and count those with positive RSI balances.
        for (uint256 i = 0; i < allUsers.length; i++) {
            if (rsiBalances[allUsers[i]] > 0) {
                userCount = userCount.add(1);
            }
        }

        return userCount;
    }

    // External function to view details of all users.
    function getUserDetails() external view returns (
        address[] memory addresses,
        uint256[] memory userRSIBalances,
        uint256[] memory userUSDCBalances,
        uint256[] memory userShareRSI,
        uint256[] memory rsiInBurnQueue,
        uint256[] memory totalUsdcReceivedByUser
    ) {
        // Get all users.
        address[] memory allUsers = getUsers();
        
        // Initialize arrays.
        addresses = new address[](allUsers.length);
        userRSIBalances = new uint256[](allUsers.length);
        userUSDCBalances = new uint256[](allUsers.length);
        userShareRSI = new uint256[](allUsers.length);
        rsiInBurnQueue = new uint256[](allUsers.length);
        totalUsdcReceivedByUser = new uint256[](allUsers.length);

        // Iterate through all users.
        for (uint256 i = 0; i < allUsers.length; i++) {
            // Set user details.
            addresses[i] = allUsers[i];
            userRSIBalances[i] = a(rsiBalances[allUsers[i]]);
            userUSDCBalances[i] = a(usdcBalances[allUsers[i]]);
            // Calculate user's share of RSI.
            uint256 totalRSI = calculateTotalRSI();
            userShareRSI[i] = a(totalRSI > 0 ? rsiBalances[allUsers[i]].div(totalRSI) : 0);
            // Calculate the amount of RSI the user has in the burn queue.
            rsiInBurnQueue[i] = a(getTotalRSIInBurnQueue(allUsers[i]));
            // Get the total USDC received by the user.
            totalUsdcReceivedByUser[i] = a(totalUsdcReceived[allUsers[i]]);
        }

        return (addresses, userRSIBalances, userUSDCBalances, userShareRSI, rsiInBurnQueue, totalUsdcReceivedByUser);
    }

    // External function to view details of a specific user.
    function getUserDetailsFor(address user) external view returns (
        address userAddress,
        uint256 rsiBalance,
        uint256 usdcBalance,
        uint256 userShareRSI,
        uint256 rsiInBurnQueue,
        uint256 totalUsdcReceivedByUser
    ) {
        // Set user details.
        userAddress = user;
        rsiBalance = a(rsiBalances[user]);
        usdcBalance = a(usdcBalances[user]);
        // Calculate user's share of RSI.
        uint256 totalRSI = a(calculateTotalRSI());
        userShareRSI = a(totalRSI > 0 ? rsiBalance.div(totalRSI) : 0);
        // Calculate the amount of RSI the user has in the burn queue.
        rsiInBurnQueue = a(getTotalRSIInBurnQueue(user));
        // Get the total USDC received by the user.
        totalUsdcReceivedByUser = a(totalUsdcReceived[user]);
        return (userAddress, rsiBalance, usdcBalance, userShareRSI, rsiInBurnQueue, totalUsdcReceivedByUser);
    }

    // Internal function to view the total amount of RSI a user has in the burn queue.
    function getTotalRSIInBurnQueue(address user) internal view returns (uint256) {
        uint256 totalRSI = 0;

        for (uint256 i = 0; i < burnQueue.length; i++) {
            if (burnQueue[i].user == user) {
                totalRSI = totalRSI.add(burnQueue[i].amount);
            }
        }

        return totalRSI;
    }

    // External function to view RSI Balance.
    function YourRSIBalance() external view returns (uint256) {
        return a(rsiBalances[msg.sender]);
    }

    // External function to view the total amount of RSI a user has in the burn queue.
    function RSIInBurnQueue(address user) external view returns (uint256) {
        uint256 totalRSI = 0;

        for (uint256 i = 0; i < burnQueue.length; i++) {
            if (burnQueue[i].user == user) {
                totalRSI = totalRSI.add(burnQueue[i].amount);
            }
        }

        return a(totalRSI);
    }

}
