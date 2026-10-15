# Museum customer and staff features

Customer pages retain the museum's Bootstrap theme. Product reviews require staff approval. Signed-in baskets save to Supabase and restore across devices. Notifications and My orders use Realtime with a 30-second polling fallback.

In admin.html set actual product prices/stock and exhibition dates/capacities. Blank stock is unknown and does not impose a stock limit. Confirmed bookings consume capacity. Activate memberships and set an expiry date to issue a valid QR membership card. Confirm bookings to issue QR tickets. Staff check-in is in check-in.html; camera, QR image and pasted codes are supported. A ticket checks in its entire booked party once. Browser camera access requires HTTPS and permission.

Review moderation, image uploads (JPEG/PNG/WebP, up to 5 MB), waiting-list promotions and check-in require a server-verified administrator. Customers can see only their own private records. Approved reviews and museum images are public.

Checkout requires a signed-in, confirmed account and reserves known stock for 15 minutes before opening the existing Jotform. A verified Jotform submission is saved idempotently through the museum-orders Edge Function. Stock is deducted once from the reserved product quantities, not from editable form text. If a reservation is no longer available, the customer is asked to start checkout again. Form submission is not itself proof of payment. Existing Jotform payment configuration remains responsible for payment collection.

Waiting lists open when confirmed places cannot accommodate the requested party. Staff can confirm a waiting-list party only when capacity permits. Cancellation of a confirmed booking notifies waiting visitors. Stock is not automatically restored by changing an order's status; staff should adjust stock for accepted returns/cancellations.

Database SQL is in docs/museum-features.sql. It represents the applied additions, not a script to rerun against an already migrated database. Regression checks in tests/museum-features.sql run entirely inside a rolled-back transaction. QR encoding uses qrcode-generator 1.4.4; camera/image decoding uses jsQR 1.4.0, both served locally with their bundled licences.

Validation: rollback database tests cover reservation limits, stock finalization/idempotency, canonical order quantities, private basket/review visibility, protected notification columns, protected finalization RPC, waiting-list promotion, customer/admin access and duplicate QR check-in. DOM checks cover store basket restore/search/reviews, notifications, membership QR cards, tickets/waiting lists, admin controls and scanner access; QR round-trip decoding passed. Physical device camera and real payment transactions were not exercised.
