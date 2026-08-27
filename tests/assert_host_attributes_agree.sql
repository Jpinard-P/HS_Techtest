-- The hosts dimension takes host_name, host_since, and host_location with
-- any_value across the host's listings, which is only honest while the
-- source repeats them identically on every listing the host owns. Today it
-- does, for all 36 hosts. If an extract ever disagrees with itself about a
-- host, this fails naming the host, instead of any_value silently picking
-- whichever version the scan happened to see first.

select
    host_id,
    count(distinct host_name)                  as names,
    count(distinct host_since)                 as since_values,
    count(distinct coalesce(host_location, '')) as locations
from {{ ref('stg_listings') }}
group by 1
having count(distinct host_name) > 1
    or count(distinct host_since) > 1
    or count(distinct coalesce(host_location, '')) > 1
