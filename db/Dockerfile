FROM postgis/postgis:18-3.6

# The base image's own initdb hook creates postgis_topology/tiger_geocoder
# and a template_postgis database on first boot, which leaves extra schemas
# (topology, tiger, tiger_data) that Atlas has never heard of and rejects as
# "not clean". Extension setup is owned by the versioned migrations instead
# (see migrations/..._gdacs_hazards.sql), so drop the hook.
RUN rm -f /docker-entrypoint-initdb.d/10_postgis.sh

EXPOSE 5432