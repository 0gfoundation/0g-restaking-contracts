// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IAscendRouter {
    /// @dev Error thrown when parameters are invalid
    error AscendRouterInvalidParams();

    /**
     * @dev Event emitted when ETH is distributed to a recipient
     * @param recipient Address of the recipient
     * @param amount Amount of WETH distributed
     */
    event Distributed(address indexed recipient, uint256 amount);

    /**
     * @dev Updates the distribution parameters
     * @param mellowVault Address of mellowVault recipient
     * @param foundation Address of foundation recipient
     * @param paymentLayer Address of paymentLayer recipient
     * @param mellowVaultPercentage Percentage for mellowVault (18 decimals)
     * @param foundationPercentage Percentage for foundation (18 decimals)
     * @param paymentLayerPercentage Percentage for paymentLayer (18 decimals)
     */
    function updateParams(
        address mellowVault,
        address foundation,
        address paymentLayer,
        uint256 mellowVaultPercentage,
        uint256 foundationPercentage,
        uint256 paymentLayerPercentage
    ) external;

    /**
     * @dev Distributes ETH balance to recipients as WETH
     */
    function distribute() external;

    /**
     * @dev Returns current distribution parameters
     * @return WETH Address of WETH contract
     * @return mellowVault Address of mellowVault recipient
     * @return foundation Address of foundation recipient
     * @return paymentLayer Address of paymentLayer recipient
     * @return mellowVaultPercentage Percentage for mellowVault (18 decimals)
     * @return foundationPercentage Percentage for foundation (18 decimals)
     * @return paymentLayerPercentage Percentage for paymentLayer (18 decimals)
     */
    function getParams()
        external
        view
        returns (
            address WETH,
            address mellowVault,
            address foundation,
            address paymentLayer,
            uint256 mellowVaultPercentage,
            uint256 foundationPercentage,
            uint256 paymentLayerPercentage
        );
}
