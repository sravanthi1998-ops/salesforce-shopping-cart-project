import { LightningElement, api, wire, track } from 'lwc';
import getCartForAccount from '@salesforce/apex/CartService.getCartForAccount';
import removeLineItem from '@salesforce/apex/CartService.removeLineItem';
import submitOrder from '@salesforce/apex/CartService.submitOrder';

import CART_MESSAGE from '@salesforce/messageChannel/CartMessageChannel__c';
import { subscribe, publish, MessageContext } from 'lightning/messageService';

import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

export default class ShoppingCart extends LightningElement {

    @api recordId;

    @track cart;
    @track items = [];

    subscription = null;
    cartResult;    

    @wire(MessageContext)
    messageContext;

    // Load cart
    @wire(getCartForAccount, { accountId: '$recordId' })
    wiredCart(result) {
        this.cartResult = result;

        if (result.data) {
            this.cart = result.data;
            this.items = result.data.items || [];
        }
    }

    connectedCallback() {
        this.subscribeToMessageChannel();
    }

    subscribeToMessageChannel() {
        if (this.subscription) return;

        this.subscription = subscribe(
            this.messageContext,
            CART_MESSAGE,
            (message) => {
                if (message.accountId === this.recordId) {
                    this.refreshCart();
                }
            }
        );
    }

    // Refresh Cart  
    refreshCart() {
        if (!this.cartResult) {
            setTimeout(() => this.refreshCart(), 200);
            return;
        }

        refreshApex(this.cartResult).catch(error => {
            console.error('Refresh error:', JSON.stringify(error));
        });
    }

    // Remove item from cart
    handleRemove(event) {
        const lineItemId = event.target.dataset.id;

        removeLineItem({ lineItemId, accountId: this.recordId })
            .then(result => {
                this.cart = result;
                this.items = result ? result.items : [];

                this.showToast('Removed', 'Item removed from cart', 'success');

                return refreshApex(this.cartResult);
            })
            .catch(error => {
                this.showToast('Error', error.body?.message || 'Unknown error', 'error');
            });
    }

    // Submit order
    handleSubmitOrder() {

        if (!this.cart || !this.cart.opportunityId) {
            this.showToast('Error', 'No active cart found.', 'error');
            return;
        }

        submitOrder({
            opportunityId: this.cart.opportunityId,
            accountId: this.recordId
        })
        .then(() => {
            this.showToast('Order Submitted', 'Cart submitted successfully', 'success');

            // Tell ProductSelector to reset its UI
            publish(this.messageContext, CART_MESSAGE, {
                accountId: this.recordId,
                status: 'submitted'
            });

            // Clear cart UI after submit
            this.cart = null;
            this.items = [];
        })
        .catch(error => {
            this.showToast('Error', error.body?.message || 'Unknown error', 'error');
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}