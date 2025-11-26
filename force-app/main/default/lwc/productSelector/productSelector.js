import { LightningElement, api, wire, track } from 'lwc';
import getActiveProducts from '@salesforce/apex/CartService.getActiveProducts';
import addProductsToCart from '@salesforce/apex/CartService.addProductsToCart';
import { publish, subscribe, MessageContext } from 'lightning/messageService';
import CART_MESSAGE from '@salesforce/messageChannel/CartMessageChannel__c';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class ProductSelector extends LightningElement {

    @api recordId;

    @track data = [];
    @track draftValues = [];
    selectedRows = [];

    subscription = null; 

    columns = [
        { label: 'Product Name', fieldName: 'name', type: 'text' },
        { label: 'Price', fieldName: 'unitPrice', type: 'currency' },
        {
            label: 'Qty',
            fieldName: 'quantity',
            type: 'number',
            editable: true,
            cellAttributes: { alignment: 'center' }
        }
    ];

    @wire(MessageContext)
    messageContext;

    //Listen for order submission
    connectedCallback() {
        if (!this.subscription) {
            this.subscription = subscribe(
                this.messageContext,
                CART_MESSAGE,
                (message) => this.handleCartMessage(message)
            );
        }
    }

    //Reset after submission
    handleCartMessage(message) {
        if (message.status === 'submitted') {

            // Clear selected rows
            const table = this.template.querySelector('lightning-datatable');
            if (table) {
                table.selectedRows = [];
            }

            // Reset internal selection
            this.selectedRows = [];

            // Reset quantities to 1
            this.data = this.data.map(item => ({ ...item, quantity: 1 }));
        }
    }

    // Load products
    @wire(getActiveProducts)
    wiredProducts({ data, error }) {
        if (data) {
            this.data = data.map(item => ({
                id: item.productId,
                productId: item.productId,
                name: item.name,
                unitPrice: item.unitPrice,
                quantity: 1
            }));

        } else if (error) {
            console.error(error);
        }
    }

    // Handle quantity edit
    handleCellChange(event) {
        const updates = event.detail.draftValues;

        updates.forEach(update => {
            const row = this.data.find(r => r.id === update.id);
            if (row) {
                row.quantity = update.quantity;
            }
        });

        this.draftValues = [];
    }

    // Row selection
    handleRowSelection(event) {
        const rows = event.detail.selectedRows;

        // commit draft quantity edits before selection
        rows.forEach(r => {
            const original = this.data.find(x => x.id === r.id);
            if (original) {
                r.quantity = original.quantity; 
            }
        });

        this.selectedRows = rows.map(r => ({
            productId: r.productId ?? r.id,
            quantity: Number(r.quantity)
        }));
    }

    // Add to cart
    handleAddToCart() {

        if (!this.selectedRows.length) {
            this.showToast('No products selected', 'Please select at least one product.', 'warning');
            return;
        }

        // Sync latest edited quantities
        const payload = this.selectedRows.map(sel => {
            const row = this.data.find(r => r.id === sel.productId || r.id === sel.id);
            return {
                productId: sel.productId ?? sel.id,
                quantity: Number(row?.quantity ?? sel.quantity)
            };
        });

        addProductsToCart({
            accountId: this.recordId,
            selectedProducts: payload
        })
        .then(result => {
            this.showToast('Cart Updated', 'Products added successfully!', 'success');

            // Notify Shopping Cart LWC
            publish(this.messageContext, CART_MESSAGE, {
                accountId: this.recordId
            });

            // CLEAR ALL ROW SELECTIONS
            const datatable = this.template.querySelector('lightning-datatable');
            if (datatable) {
                datatable.selectedRows = [];      
            }
            this.selectedRows = [];               

        })
        .catch(error => {
            this.showToast('Error', error.body.message, 'error');
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}