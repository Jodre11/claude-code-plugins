/** Wire-contract DTO for invoice events. */
export interface InvoicePayload {
  invoiceId: string;
  customerId: string;
  totalAmount: number;
  lineItems: Array<{ sku: string; quantity: number; unitPrice: number }>;
}

/**
 * Publishes an invoice-created event to the message bus.
 * The payload must be fully populated before emission.
 */
export function emitInvoiceCreated(
  bus: { publish: (topic: string, payload: InvoicePayload) => void },
  payload: InvoicePayload,
): void {
  bus.publish("invoice.created", payload);
}
