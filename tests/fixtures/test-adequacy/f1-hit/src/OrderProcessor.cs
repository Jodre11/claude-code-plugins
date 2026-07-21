namespace Shop.Orders;

/// <summary>
/// Processes customer orders and calculates the final charge.
/// </summary>
public class OrderProcessor
{
    private const decimal TaxRate = 0.20m;

    /// <summary>
    /// Calculates the total order charge including tax and applies a loyalty discount
    /// when the customer has more than 10 previous orders.
    /// </summary>
    public decimal CalculateCharge(decimal subtotal, int previousOrders)
    {
        var discount = previousOrders > 10 ? 0.05m : 0m;
        var discounted = subtotal * (1m - discount);
        return discounted * (1m + TaxRate);
    }
}
