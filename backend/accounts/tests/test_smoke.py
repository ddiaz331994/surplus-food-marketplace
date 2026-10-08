import pytest
from django.contrib.gis.geos import Point
from django.db import connection

from accounts.models import User


@pytest.mark.django_db
def test_create_user_defaults_to_consumer():
    user = User.objects.create_user(email="Shopper@Example.com", password="x-strong-pass-1")
    assert user.email == "Shopper@example.com"
    assert user.role == User.Role.CONSUMER
    assert user.check_password("x-strong-pass-1")


@pytest.mark.django_db
def test_postgis_distance():
    # GDAL/GEOS load locally and PostGIS answers geography queries.
    p = Point(-87.6298, 41.8781, srid=4326)
    assert p.transform(3857, clone=True).srid == 3857
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT ST_Distance(ST_MakePoint(-87.6298,41.8781)::geography, ST_MakePoint(-87.6233,41.8827)::geography)"
        )
        assert 600 < cursor.fetchone()[0] < 900


def test_health(client, db):
    resp = client.get("/api/health/")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
