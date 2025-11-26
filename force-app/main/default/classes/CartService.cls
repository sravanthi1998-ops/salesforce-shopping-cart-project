public with sharing class CartService {

    public class ProductWrapper {
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }

        public ProductWrapper() {}
    }

    public class SelectedProduct {
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }

        public SelectedProduct() {}
    }

    public class CartItemWrapper {
        @AuraEnabled public Id lineItemId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal lineTotal { get; set; }

        public CartItemWrapper() {}
    }

    public class CartWrapper {
        @AuraEnabled public Id opportunityId { get; set; }
        @AuraEnabled public Decimal cartTotal { get; set; }
        @AuraEnabled public List<CartItemWrapper> items { get; set; }

        public CartWrapper() {}
    }

    // GET STANDARD PRICEBOOK
    private static Pricebook2 getStandardPricebook() {
        Pricebook2 pb = [
            SELECT Id, IsActive
            FROM Pricebook2
            WHERE IsStandard = true
            LIMIT 1
        ];
        if (!pb.IsActive) {
            pb.IsActive = true;
            update pb;
        }
        return pb;
    }

    // GET ACTIVE PRODUCTS
    @AuraEnabled(cacheable=true)
    public static List<ProductWrapper> getActiveProducts() {
        Pricebook2 stdPb = getStandardPricebook();
        List<ProductWrapper> results = new List<ProductWrapper>();

        for (Product2 p : [
            SELECT Id, Name,
               (SELECT Id, UnitPrice, IsActive
                FROM PricebookEntries
                WHERE Pricebook2Id = :stdPb.Id AND IsActive = true
                LIMIT 1)
            FROM Product2
            WHERE IsActive = true
            ORDER BY Name ASC
        ]) {
            if (!p.PricebookEntries.isEmpty()) {
                ProductWrapper w = new ProductWrapper();
                w.productId = p.Id;
                w.name      = p.Name;
                w.unitPrice = p.PricebookEntries[0].UnitPrice;
                results.add(w);
            }
        }
        return results;
    }

    // GET OR CREATE CART
    private static Opportunity getOrCreateOpenCart(Id accountId) {
        Account acc = [
            SELECT Id, Name
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        String estTimestamp = Datetime.now().format(
            'yyyyMMdd_HHmmss',
            'America/New_York'
        );

        Opportunity cart;
        List<Opportunity> carts = [
            SELECT Id, Name, StageName, IsClosed,
                   AccountId, Cart_Status__c, Pricebook2Id
            FROM Opportunity
            WHERE AccountId = :accountId
              AND IsClosed   = false
              AND Cart_Status__c = 'Open Cart'
            LIMIT 1
        ];

        if (!carts.isEmpty()) {
            cart = carts[0];
        } else {
            Pricebook2 stdPb = getStandardPricebook();
            cart = new Opportunity(
                Name            = acc.Name + ' Cart - ' + estTimestamp,
                StageName       = 'Prospecting',
                CloseDate       = Date.today().addDays(30),
                AccountId       = accountId,
                Cart_Status__c  = 'Open Cart',
                Pricebook2Id    = stdPb.Id
            );
            insert cart;
        }
        return cart;
    }

    // ADD PRODUCTS TO CART
    @AuraEnabled
    public static CartWrapper addProductsToCart(Id accountId, List<SelectedProduct> selectedProducts) {

        if (accountId == null || selectedProducts == null || selectedProducts.isEmpty()) {
            return null;
        }

        Opportunity cart = getOrCreateOpenCart(accountId);
        Pricebook2 stdPb = getStandardPricebook();

        // Collect Product2 Ids
        Set<Id> productIds = new Set<Id>();
        for (SelectedProduct sp : selectedProducts) {
            if (sp != null && sp.productId != null) {
                productIds.add(sp.productId);
            }
        }

        // Query all pricebook entries
        Map<Id, PricebookEntry> pbeMap = new Map<Id, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, UnitPrice
            FROM PricebookEntry
            WHERE Pricebook2Id = :stdPb.Id
              AND Product2Id   IN :productIds
              AND IsActive     = true
        ]) {
            pbeMap.put(pbe.Product2Id, pbe);
        }

        List<OpportunityLineItem> insertList = new List<OpportunityLineItem>();

        for (SelectedProduct sp : selectedProducts) {
            if (sp == null || sp.productId == null || sp.quantity == null || sp.quantity <= 0)
                continue;

            PricebookEntry pbe = pbeMap.get(sp.productId);
            if (pbe == null)
                continue;

            insertList.add(new OpportunityLineItem(
                OpportunityId    = cart.Id,
                PricebookEntryId = pbe.Id,
                Quantity         = sp.quantity,
                UnitPrice        = pbe.UnitPrice
            ));
        }

        if (!insertList.isEmpty()) {
            insert insertList;
        }

        return getCartForAccount(accountId);
    }

    // GET CART
    @AuraEnabled(cacheable=true)
    public static CartWrapper getCartForAccount(Id accountId) {
        if (accountId == null) return null;

        List<Opportunity> carts = [
            SELECT Id, Name, Cart_Status__c, IsClosed,
                   (SELECT Id, Quantity, TotalPrice, UnitPrice, Product2.Name
                    FROM OpportunityLineItems)
            FROM Opportunity
            WHERE AccountId = :accountId
              AND IsClosed   = false
              AND Cart_Status__c = 'Open Cart'
            LIMIT 1
        ];

        if (carts.isEmpty()) return null;

        Opportunity cart = carts[0];

        CartWrapper wrapper = new CartWrapper();
        wrapper.opportunityId = cart.Id;
        wrapper.items = new List<CartItemWrapper>();

        Decimal total = 0;

        for (OpportunityLineItem oli : cart.OpportunityLineItems) {
            CartItemWrapper ci = new CartItemWrapper();
            ci.lineItemId  = oli.Id;
            ci.productName = oli.Product2 != null ? oli.Product2.Name : '';
            ci.unitPrice   = oli.UnitPrice;
            ci.quantity    = oli.Quantity;
            ci.lineTotal   = oli.TotalPrice;
            total += oli.TotalPrice;
            wrapper.items.add(ci);
        }

        wrapper.cartTotal = total;
        return wrapper;
    }

    // REMOVE LINE ITEM
    @AuraEnabled
    public static CartWrapper removeLineItem(Id lineItemId, Id accountId) {
        if (lineItemId != null) {
            delete [SELECT Id FROM OpportunityLineItem WHERE Id = :lineItemId];
        }
        return getCartForAccount(accountId);
    }

    // SUBMIT ORDER
    @AuraEnabled
    public static CartWrapper submitOrder(Id opportunityId, Id accountId) {
        if (opportunityId == null) return null;

        Opportunity opp = [
            SELECT Id, StageName, IsClosed, Cart_Status__c
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];

        opp.StageName      = 'Closed Won';
        opp.Cart_Status__c = 'Submitted';
        update opp;

        return null;
    }
}