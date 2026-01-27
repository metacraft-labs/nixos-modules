#!/usr/bin/env dub
/+ dub.sdl:
    name "test_coda"
    dependency "mcl" path="."
+/

module test_coda;

import std.array : array;
import std.algorithm : map, sort, uniq;
import std.conv : to;
import std.stdio : writeln, writefln;
import std.traits : EnumMembers;

import mcl.commands.invoices : loadInvoiceItems, Product, ProductCategory;

void main(string[] args)
{
    import mcl.commands.invoices.list : groupInvoiceItemsByProduct;

    // Load invoice items
    writeln("Loading invoice items...");
    auto items = loadInvoiceItems("../inventory/jar-invoices/");
    writefln("  Loaded %d items\n", items.length);

    // Extract unique products (across all categories)
    Product[] products;
    static foreach (cat; EnumMembers!ProductCategory)
    {
        {
            auto categoryProducts = groupInvoiceItemsByProduct(items, cat);
            foreach (ref po; categoryProducts)
                products ~= po.product;
        }
    }

    // Extract unique vendors from products
    auto vendors = products
        .map!(p => p.vendor)
        .array
        .sort
        .uniq
        .array;

    // Print vendors
    writeln("=== Unique Vendors ===\n");
    foreach (vendor; vendors)
    {
        writeln("- ", vendor);
    }
}
