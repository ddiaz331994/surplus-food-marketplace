from django.db import connection
from django.utils import timezone
from drf_spectacular.utils import extend_schema, inline_serializer
from rest_framework import serializers
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response


@extend_schema(
    responses=inline_serializer(
        "Health",
        {
            "status": serializers.CharField(),
            "postgis": serializers.CharField(),
            "server_time": serializers.DateTimeField(),
        },
    )
)
@api_view(["GET"])
@permission_classes([AllowAny])
def health(request):
    """Liveness check. server_time lets clients compute their clock offset for countdowns."""
    with connection.cursor() as cursor:
        cursor.execute("SELECT postgis_lib_version()")
        postgis = cursor.fetchone()[0]
    return Response({"status": "ok", "postgis": postgis, "server_time": timezone.now()})
