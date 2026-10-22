#!/usr/bin/env python3
"""Writes the sample models in samples/ (deterministic, so re-running gives the same files)."""
import os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from dmm import Model

root = os.path.join(os.path.dirname(__file__), "..", "samples")

# --- social: users, posts, follows, with embedded profile and comments.
m = Model("Social", random.Random(1))
profile = m.table("users_profile", [("displayName", "String", {"nn"}), ("bio", "String"), ("avatarUrl", "String")], "embedded in users", embeddable=True)
users = m.table("users", [("_id", "ObjectId", {"pk"}), ("username", "String", ({"nn"}, "unique, lowercase")), ("email", "String", {"nn"}),
                          ("profile", profile, {"nn"}), ("created", "Date", {"nn"})], "People who post.")
m.embed(users, "profile", profile)
comments = m.table("posts_comments", [("authorId", "ObjectId", {"nn"}), ("text", "String", {"nn"}), ("created", "Date", {"nn"})],
                   "embedded in posts", embeddable=True)
posts = m.table("posts", [("_id", "ObjectId", {"pk"}), ("authorId", "ObjectId", {"nn"}), ("title", "String", {"nn"}),
                          ("body", "String", ({"nn"}, "Markdown")), ("tags", "String", {"list"}), ("comments", comments, {"list"}),
                          ("status", "String", ({"nn"}, "draft | published")), ("created", "Date", {"nn"})], "Posts, with their comments inline.")
m.embed(posts, "comments", comments)
follows = m.table("follows", [("_id", "ObjectId", {"pk"}), ("followerId", "ObjectId", {"nn"}), ("followingId", "ObjectId", {"nn"}),
                              ("created", "Date", {"nn"})], "Who follows whom.")
m.ref(posts, "authorId", users)
m.ref(follows, "followerId", users)
m.ref(follows, "followingId", users)
m.diagram("Main Diagram", {users: (40, 40), profile: (40, 220), posts: (360, 40), comments: (680, 140), follows: (360, 260)},
          {users: "#3f51b5", posts: "#009688", follows: "#607d8b"})
open(os.path.join(root, "social.dmm"), "w").write(m.dumps())

# --- shop: two sub-diagrams on top of the main one.
m = Model("Shop", random.Random(2))
addr = m.table("customers_addresses", [("label", "String"), ("line1", "String", {"nn"}), ("city", "String", {"nn"}),
                                        ("country", "String", ({"nn"}, "ISO 3166-1 alpha-2"))], "embedded in customers", embeddable=True)
customers = m.table("customers", [("_id", "ObjectId", {"pk"}), ("email", "String", {"nn"}), ("name", "String", {"nn"}),
                                  ("addresses", addr, {"list"}), ("marketingOptIn", "Boolean", {"nn"}), ("created", "Date", {"nn"})],
                    "Registered shoppers.")
m.embed(customers, "addresses", addr)
categories = m.table("categories", [("_id", "ObjectId", {"pk"}), ("name", "String", {"nn"}), ("parentId", "ObjectId")], "Category tree.")
price = m.table("products_price", [("amount", "Number", {"nn"}), ("currency", "String", {"nn"})], "embedded in products", embeddable=True)
products = m.table("products", [("_id", "ObjectId", {"pk"}), ("sku", "String", ({"nn"}, "unique")), ("name", "String", {"nn"}),
                                ("categoryId", "ObjectId", {"nn"}), ("price", price, {"nn"}), ("images", "String", {"list"}),
                                ("stock", "Number", {"nn"}), ("active", "Boolean", {"nn"})], "Things we sell.")
m.embed(products, "price", price)
items = m.table("orders_items", [("productId", "ObjectId", {"nn"}), ("quantity", "Number", {"nn"}), ("unitPrice", "Number", {"nn"})],
                "embedded in orders", embeddable=True)
ship = m.table("orders_shipping", [("line1", "String", {"nn"}), ("city", "String", {"nn"}), ("country", "String", {"nn"})],
               "embedded in orders", embeddable=True)
orders = m.table("orders", [("_id", "ObjectId", {"pk"}), ("customerId", "ObjectId", {"nn"}), ("items", items, {"nn", "list"}),
                            ("shipping", ship, set()), ("total", "Number", {"nn"}), ("status", "String", ({"nn"}, "pending | paid | shipped | cancelled")),
                            ("couponId", "ObjectId"), ("created", "Date", {"nn"})], "One checkout.")
m.embed(orders, "items", items)
m.embed(orders, "shipping", ship)
coupons = m.table("coupons", [("_id", "ObjectId", {"pk"}), ("code", "String", {"nn"}), ("percentOff", "Number", {"nn"}),
                              ("expires", "Date")], "Discount codes.")
reviews = m.table("reviews", [("_id", "ObjectId", {"pk"}), ("productId", "ObjectId", {"nn"}), ("customerId", "ObjectId", {"nn"}),
                              ("rating", "Number", ({"nn"}, "1 to 5")), ("text", "String"), ("created", "Date", {"nn"})], "Product reviews.")
m.ref(products, "categoryId", categories)
m.ref(categories, "parentId", categories)
m.ref(orders, "customerId", customers)
m.ref(orders, "couponId", coupons)
m.ref(reviews, "productId", products)
m.ref(reviews, "customerId", customers)
colors = {customers: "#3f51b5", categories: "#ff9800", products: "#009688", orders: "#e91e63", coupons: "#9c27b0", reviews: "#607d8b"}
m.diagram("All", {customers: (40, 40), addr: (40, 220), coupons: (40, 360), orders: (360, 40), items: (680, 40), ship: (680, 150),
                  categories: (1000, 260), products: (680, 260), price: (1000, 420), reviews: (360, 300)}, colors)
m.diagram("Catalog", {categories: (40, 40), products: (360, 40), price: (680, 40), reviews: (360, 260)}, colors)
m.diagram("Checkout", {customers: (40, 40), addr: (40, 220), orders: (360, 40), items: (680, 40), ship: (680, 150), coupons: (360, 260)}, colors)
open(os.path.join(root, "shop.dmm"), "w").write(m.dumps())
