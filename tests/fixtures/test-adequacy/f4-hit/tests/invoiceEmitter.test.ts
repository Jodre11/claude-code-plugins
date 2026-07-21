import { emitInvoiceCreated, InvoicePayload } from "../src/invoiceEmitter";

describe("emitInvoiceCreated", () => {
  it("calls publish on the bus", () => {
    const bus = { publish: jest.fn() };
    // Producer side: stub supplies an empty payload — no fields are asserted.
    const payload = {} as InvoicePayload;
    emitInvoiceCreated(bus, payload);
    expect(bus.publish).toHaveBeenCalledWith("invoice.created", payload);
  });
});
