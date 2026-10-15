alter table public.memberships add column card_token uuid not null default gen_random_uuid() unique;
alter table public.bookings add column ticket_token uuid not null default gen_random_uuid() unique, add column checked_in_at timestamptz;
alter table public.orders add column stock_processed boolean not null default false;
create table public.reviews(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,product_id text not null references public.products(id) on delete cascade,rating integer not null check(rating between 1 and 5),body text not null check(length(body) between 5 and 2000),status text not null default 'pending' check(status in ('pending','approved','rejected')),created_at timestamptz not null default now(),unique(user_id,product_id));
create table public.saved_baskets(user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,items jsonb not null default '{}' check(jsonb_typeof(items)='object' and octet_length(items::text)<=10000),updated_at timestamptz not null default now());
create table public.notifications(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id) on delete cascade,title text not null,body text not null,link text not null default 'account.html',read_at timestamptz,created_at timestamptz not null default now());
create index on public.notifications(user_id,created_at desc);
create table public.waitlist(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,exhibition_id text not null references public.exhibitions(id),quantity integer not null check(quantity between 1 and 10),status text not null default 'waiting' check(status in ('waiting','notified','booked','cancelled')),created_at timestamptz not null default now());
create unique index waitlist_one_open on public.waitlist(user_id,exhibition_id) where status in ('waiting','notified');
create index on public.waitlist(exhibition_id,created_at);
create table public.stock_reservations(token_hash text not null references public.checkout_sessions(token_hash) on delete cascade,user_id uuid not null references auth.users(id) on delete cascade,product_id text not null references public.products(id),quantity integer not null check(quantity between 1 and 99),expires_at timestamptz not null default now()+interval '15 minutes',primary key(token_hash,product_id));
create index on public.stock_reservations(product_id,expires_at);create index on public.stock_reservations(user_id);
alter table public.reviews enable row level security;alter table public.saved_baskets enable row level security;alter table public.notifications enable row level security;alter table public.waitlist enable row level security;alter table public.stock_reservations enable row level security;
create policy reviews_read on public.reviews for select to anon,authenticated using(status='approved' or user_id=(select auth.uid()));
create policy reviews_write on public.reviews for insert to authenticated with check(user_id=(select auth.uid()) and status='pending');
create policy reviews_admin on public.reviews for all to authenticated using((select museum_private.is_admin())) with check((select museum_private.is_admin()));
create policy baskets_own on public.saved_baskets for all to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
create policy notifications_read on public.notifications for select to authenticated using(user_id=(select auth.uid()));
create policy notifications_mark on public.notifications for update to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
create policy waitlist_read on public.waitlist for select to authenticated using(user_id=(select auth.uid()) or (select museum_private.is_admin()));
create policy reservations_read on public.stock_reservations for select to authenticated using(user_id=(select auth.uid()));
grant select on public.reviews to anon;
grant select,insert on public.reviews to authenticated;grant update(status) on public.reviews to authenticated;
grant select,insert,update,delete on public.saved_baskets to authenticated;
grant select on public.notifications,public.waitlist,public.stock_reservations to authenticated;grant update(read_at) on public.notifications to authenticated;
revoke all on public.stock_reservations,public.waitlist from anon;
grant all on public.stock_reservations,public.notifications,public.waitlist,public.orders,public.products,public.checkout_sessions to service_role;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('museum-images','museum-images',true,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create policy museum_images_admin on storage.objects for all to authenticated using(bucket_id='museum-images' and (select museum_private.is_admin())) with check(bucket_id='museum-images' and (select museum_private.is_admin()));
create function museum_private.notify_changes() returns trigger language plpgsql security definer set search_path='' as $$
begin
if tg_op='INSERT' or old.status is distinct from new.status then
insert into public.notifications(user_id,title,body,link) values(new.user_id,case tg_table_name when 'orders' then 'Order update' when 'memberships' then 'Membership update' else 'Booking update' end,'Your '||case tg_table_name when 'orders' then 'order' when 'memberships' then 'membership' else 'booking' end||' status is now '||new.status||'.',case tg_table_name when 'orders' then 'my-orders.html' when 'memberships' then 'my-membership.html' else 'bookings.html' end);
end if;
if tg_table_name='bookings' and tg_op='UPDATE' and old.status='confirmed' and new.status='cancelled' then
insert into public.notifications(user_id,title,body,link) select user_id,'Exhibition places may be available','Places have been released. The museum will review the waiting list.','bookings.html' from public.waitlist where exhibition_id=new.exhibition_id and status='waiting';
update public.waitlist set status='notified' where exhibition_id=new.exhibition_id and status='waiting';
end if;return new;
end $$;
revoke all on function museum_private.notify_changes() from public;
create trigger order_notifications after insert or update of status on public.orders for each row execute function museum_private.notify_changes();
create trigger member_notifications after insert or update of status on public.memberships for each row execute function museum_private.notify_changes();
create trigger booking_notifications after insert or update of status on public.bookings for each row execute function museum_private.notify_changes();
create function museum_private.customer_action(action text,payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); ex public.exhibitions; item record; prod public.products; held integer; qty integer; h text; target uuid; rowdata record; cap integer; used integer; ticket uuid;
begin
if uid is null then raise exception 'Sign in first';end if;
if not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null and deleted_at is null) then raise exception 'Confirm your email first';end if;
if action='reserve' then
h:=payload->>'token_hash';if h!~'^[a-f0-9]{64}$' or not exists(select 1 from public.checkout_sessions where token_hash=h and user_id=uid) then raise exception 'Invalid checkout';end if;
if jsonb_typeof(payload->'items')<>'object' or (select count(*) from jsonb_object_keys(payload->'items')) not between 1 and 30 then raise exception 'Invalid basket';end if;
perform 1 from auth.users where id=uid for update;
-- Lock catalogue rows in a fixed order for safe concurrent checkouts.
perform 1 from public.products where id in(select jsonb_object_keys(payload->'items')) order by id for update;
delete from public.stock_reservations where user_id=uid or expires_at<=now();
for item in select * from jsonb_each_text(payload->'items') order by key loop
if item.value!~'^[0-9]{1,2}$' then raise exception 'Invalid quantity';end if;qty:=item.value::integer;if qty<1 then raise exception 'Invalid quantity';end if;
select * into prod from public.products where id=item.key and active;if not found then raise exception 'Product unavailable';end if;
select coalesce(sum(quantity),0) into held from public.stock_reservations where product_id=prod.id and expires_at>now();
if prod.stock is not null and prod.stock-held<qty then raise exception 'Not enough stock for %',prod.name;end if;
insert into public.stock_reservations(token_hash,user_id,product_id,quantity) values(h,uid,prod.id,qty);
end loop;return jsonb_build_object('expires_at',now()+interval '15 minutes');
elsif action='join_waitlist' then
select * into ex from public.exhibitions where id=payload->>'exhibition_id' and active for update;if not found then raise exception 'Exhibition unavailable';end if;
qty:=(payload->>'quantity')::integer;if qty not between 1 and 10 then raise exception 'Choose 1 to 10 places';end if;
select coalesce(sum(quantity),0) into used from public.bookings where exhibition_id=ex.id and status='confirmed';
if ex.capacity is null or used+qty<=ex.capacity then raise exception 'Places are available; request a booking instead';end if;
if exists(select 1 from public.bookings where user_id=uid and exhibition_id=ex.id and status in ('requested','confirmed')) then raise exception 'You already have a booking request';end if;
insert into public.waitlist(user_id,exhibition_id,quantity) values(uid,ex.id,qty);return '{"success":true}'::jsonb;
elsif action='leave_waitlist' then
update public.waitlist set status='cancelled' where id=(payload->>'id')::uuid and user_id=uid and status in ('waiting','notified');return '{"success":true}'::jsonb;
elsif action='availability' then
return (select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'available',case when e.capacity is null then null else greatest(0,e.capacity-coalesce(b.used,0)) end)),'[]') from public.exhibitions e left join(select exhibition_id,sum(quantity)::integer used from public.bookings where status='confirmed' group by exhibition_id)b on b.exhibition_id=e.id where e.active);
end if;
if not museum_private.is_admin() then raise exception 'Administrator access required';end if;
if action='check_ticket' then
select * into rowdata from public.bookings where ticket_token=(payload->>'token')::uuid for update;
if not found then raise exception 'Ticket not found';end if;
if rowdata.status<>'confirmed' then raise exception 'This booking is not confirmed';end if;
if rowdata.checked_in_at is not null then return jsonb_build_object('already_used',true,'checked_in_at',rowdata.checked_in_at,'places',rowdata.quantity);end if;
update public.bookings set checked_in_at=now() where id=rowdata.id;return jsonb_build_object('success',true,'places',rowdata.quantity,'booking_id',rowdata.id);
elsif action='check_member' then
select * into rowdata from public.memberships where card_token=(payload->>'token')::uuid;
if not found then raise exception 'Membership not found';end if;
if rowdata.status<>'active' or rowdata.expires_on is null or rowdata.expires_on<current_date then raise exception 'Membership is not active or has expired';end if;
return jsonb_build_object('success',true,'plan',rowdata.plan,'expires_on',rowdata.expires_on,'member_number',rowdata.id,'name',(select full_name from public.profiles where user_id=rowdata.user_id));
elsif action='promote_waitlist' then
select * into rowdata from public.waitlist where id=(payload->>'id')::uuid and status in ('waiting','notified') for update;if not found then raise exception 'Waiting-list request unavailable';end if;
select * into ex from public.exhibitions where id=rowdata.exhibition_id and active for update;if not found or ex.capacity is null then raise exception 'Set an active exhibition and its capacity first';end if;
select coalesce(sum(quantity),0) into used from public.bookings where exhibition_id=ex.id and status='confirmed';if used+rowdata.quantity>ex.capacity then raise exception 'Not enough places available';end if;
insert into public.bookings(user_id,exhibition_id,quantity,status) values(rowdata.user_id,ex.id,rowdata.quantity,'confirmed') returning ticket_token into ticket;
update public.waitlist set status='booked' where id=rowdata.id;
insert into public.notifications(user_id,title,body,link) values(rowdata.user_id,'Waiting-list place confirmed','Your exhibition places are confirmed. Your ticket is ready.','bookings.html');return jsonb_build_object('success',true);
end if;raise exception 'Unknown action';
end $$;
revoke all on function museum_private.customer_action(text,jsonb) from public;grant execute on function museum_private.customer_action(text,jsonb) to authenticated;
create function public.museum_action(action text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select museum_private.customer_action(action,payload)$$;
revoke all on function public.museum_action(text,jsonb) from public;grant execute on function public.museum_action(text,jsonb) to authenticated;
-- Finalisation is callable only by the authenticated order-verification backend.
create or replace function public.museum_finalize_order(owner_id uuid,checkout_hash text,submission_id text,order_summary text,delivery_method text) returns uuid language plpgsql security invoker set search_path='' as $$
declare existing public.orders; r record; p public.products; held integer; oid uuid; canonical text;
begin
perform 1 from public.checkout_sessions where token_hash=checkout_hash and user_id=owner_id for update;if not found then raise exception 'Invalid checkout owner';end if;
select * into existing from public.orders where jotform_submission_id=submission_id;if found then if existing.user_id<>owner_id then raise exception 'Order ownership mismatch';end if;return existing.id;end if;
perform 1 from public.products where id in(select product_id from public.stock_reservations where token_hash=checkout_hash and user_id=owner_id) order by id for update;
if not exists(select 1 from public.stock_reservations where token_hash=checkout_hash and user_id=owner_id) then
raise exception 'This basket reservation is no longer available. Return to the store and check out again.';
end if;
select string_agg(pr.name||' × '||sr.quantity::text,E'\n' order by pr.id) into canonical from public.stock_reservations sr join public.products pr on pr.id=sr.product_id where sr.token_hash=checkout_hash and sr.user_id=owner_id;
for r in select * from public.stock_reservations where token_hash=checkout_hash and user_id=owner_id loop
select * into p from public.products where id=r.product_id;
select coalesce(sum(quantity),0) into held from public.stock_reservations where product_id=p.id and token_hash<>checkout_hash and expires_at>now();
if p.stock is not null then if p.stock-held<r.quantity then raise exception 'Stock reservation expired and stock is no longer available for %',p.name;end if;update public.products set stock=stock-r.quantity where id=p.id;end if;
end loop;
insert into public.orders(user_id,jotform_submission_id,summary,delivery,stock_processed) values(owner_id,submission_id,canonical,delivery_method,true) returning id into oid;
delete from public.stock_reservations where token_hash=checkout_hash;return oid;
end $$;
revoke all on function public.museum_finalize_order(uuid,text,text,text,text) from public,anon,authenticated;grant execute on function public.museum_finalize_order(uuid,text,text,text,text) to service_role;
do $$begin
if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='orders') then alter publication supabase_realtime add table public.orders;end if;
if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') then alter publication supabase_realtime add table public.notifications;end if;
end $$;

revoke all on public.notifications from anon,authenticated;grant select on public.notifications to authenticated;grant update(read_at) on public.notifications to authenticated;
