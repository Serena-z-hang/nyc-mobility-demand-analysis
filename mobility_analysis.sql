-- ============================================================
-- NYC Taxi Demand & Operations Analysis
-- Author: Junzhi Zhang
-- Tools: DuckDB SQL
-- Data: NYC TLC Yellow Taxi Trip Records, January 2026
-- ============================================================

-- NOTE:
-- The paths below follow the Google Colab environment used in
-- the analysis. Update them if running the project locally.


-- ============================================================
-- 1. LOAD SOURCE DATA
-- ============================================================

CREATE OR REPLACE VIEW raw_trips AS
SELECT *
FROM read_parquet('/content/yellow_tripdata_2026-01.parquet');


CREATE OR REPLACE VIEW zone_lookup AS
SELECT *
FROM read_csv_auto('/content/taxi_zone_lookup.csv');


-- Raw dataset size
SELECT COUNT(*) AS raw_trip_count
FROM raw_trips;



-- ============================================================
-- 2. DATA QUALITY PROFILE
-- ============================================================

SELECT
    COUNT(*) AS total_rows,

    SUM(CASE
        WHEN trip_distance <= 0
        THEN 1 ELSE 0
    END) AS nonpositive_distance,

    SUM(CASE
        WHEN fare_amount < 0
        THEN 1 ELSE 0
    END) AS negative_fare,

    SUM(CASE
        WHEN tpep_dropoff_datetime <= tpep_pickup_datetime
        THEN 1 ELSE 0
    END) AS invalid_time_order

FROM raw_trips;



-- ============================================================
-- 3. BASIC CLEANING
-- ============================================================

CREATE OR REPLACE VIEW clean_trips AS
SELECT *
FROM raw_trips
WHERE trip_distance > 0
  AND fare_amount >= 0
  AND tpep_dropoff_datetime > tpep_pickup_datetime;


SELECT COUNT(*) AS clean_trip_count
FROM clean_trips;



-- ============================================================
-- 4. CREATE TRIP-LEVEL OPERATIONAL METRICS
-- ============================================================

CREATE OR REPLACE VIEW analysis_trips AS

WITH trip_metrics AS (

    SELECT
        *,

        DATE_DIFF(
            'second',
            tpep_pickup_datetime,
            tpep_dropoff_datetime
        ) / 60.0 AS duration_min

    FROM clean_trips
)

SELECT
    *,

    trip_distance /
    (duration_min / 60.0) AS avg_speed_mph

FROM trip_metrics

WHERE duration_min > 0

  -- Remove clearly implausible trip speeds
  AND trip_distance /
      (duration_min / 60.0) <= 80;



-- ============================================================
-- 5. FINAL ANALYTICAL DATASET
-- ============================================================

CREATE OR REPLACE VIEW final_trips AS

SELECT *
FROM analysis_trips

WHERE total_amount >= 0

  -- Conservative upper limit to remove extreme duration errors
  AND duration_min <= 240;


SELECT COUNT(*) AS final_trip_count
FROM final_trips;



-- ============================================================
-- 6. DISTRIBUTION / SANITY CHECKS
-- ============================================================

SELECT
    MEDIAN(trip_distance) AS median_distance,
    QUANTILE_CONT(trip_distance, 0.95) AS p95_distance,
    QUANTILE_CONT(trip_distance, 0.99) AS p99_distance,

    MEDIAN(fare_amount) AS median_fare,
    QUANTILE_CONT(fare_amount, 0.99) AS p99_fare,

    MEDIAN(duration_min) AS median_duration_min,
    QUANTILE_CONT(duration_min, 0.99) AS p99_duration_min,

    MEDIAN(avg_speed_mph) AS median_speed_mph,
    QUANTILE_CONT(avg_speed_mph, 0.99) AS p99_speed_mph

FROM final_trips;



-- ============================================================
-- 7. CITYWIDE HOURLY PICKUP ACTIVITY
-- ============================================================

SELECT
    EXTRACT(HOUR FROM tpep_pickup_datetime) AS hour,
    COUNT(*) AS pickups

FROM final_trips

GROUP BY hour
ORDER BY hour;



-- ============================================================
-- 8. ZONE-LEVEL HOURLY PICKUPS
-- ============================================================

SELECT
    z.Borough,
    z.Zone,
    EXTRACT(HOUR FROM t.tpep_pickup_datetime) AS hour,
    COUNT(*) AS pickups

FROM final_trips t

JOIN zone_lookup z
    ON t.PULocationID = z.LocationID

WHERE z.Zone IS NOT NULL

GROUP BY
    z.Borough,
    z.Zone,
    hour

ORDER BY
    pickups DESC;



-- ============================================================
-- 9. RELATIVE DEMAND CONCENTRATION / OVER-INDEX
-- ============================================================

-- Over-index compares the share of a zone's trips occurring
-- during a specific hour with the citywide share in that hour.
--
-- > 1 = zone is more concentrated in that hour than NYC overall
-- = 1 = similar to citywide hourly pattern
-- < 1 = less concentrated than NYC overall


WITH zone_hourly AS (

    SELECT
        z.Borough,
        z.Zone,
        EXTRACT(HOUR FROM t.tpep_pickup_datetime) AS hour,
        COUNT(*) AS pickups

    FROM final_trips t

    JOIN zone_lookup z
        ON t.PULocationID = z.LocationID

    WHERE z.Zone IS NOT NULL

    GROUP BY
        z.Borough,
        z.Zone,
        hour
),

zone_totals AS (

    SELECT
        Borough,
        Zone,
        SUM(pickups) AS zone_total_pickups

    FROM zone_hourly

    GROUP BY
        Borough,
        Zone
),

city_hourly AS (

    SELECT
        hour,
        SUM(pickups) AS city_hour_pickups

    FROM zone_hourly

    GROUP BY hour
),

city_total AS (

    SELECT
        SUM(pickups) AS city_total_pickups

    FROM zone_hourly
)

SELECT
    zh.Borough,
    zh.Zone,
    zh.hour,
    zh.pickups,

    ROUND(
        (
            zh.pickups * 1.0 /
            zt.zone_total_pickups
        )
        /
        (
            ch.city_hour_pickups * 1.0 /
            ct.city_total_pickups
        ),
        2
    ) AS over_index

FROM zone_hourly zh

JOIN zone_totals zt
    ON zh.Borough = zt.Borough
    AND zh.Zone = zt.Zone

JOIN city_hourly ch
    ON zh.hour = ch.hour

CROSS JOIN city_total ct

WHERE zt.zone_total_pickups >= 20000

ORDER BY over_index DESC;



-- ============================================================
-- 10. PICKUP–DROPOFF ASYMMETRY
-- ============================================================

-- Imbalance Index:
--
-- (pickups - dropoffs) / (pickups + dropoffs)
--
-- Positive = pickup-heavy
-- Near zero = relatively balanced
-- Negative = dropoff-heavy
--
-- IMPORTANT:
-- This does NOT directly measure driver supply.


WITH pickups AS (

    SELECT
        z.Borough,
        z.Zone,
        EXTRACT(HOUR FROM t.tpep_pickup_datetime) AS hour,
        COUNT(*) AS pickups

    FROM final_trips t

    JOIN zone_lookup z
        ON t.PULocationID = z.LocationID

    WHERE z.Zone IS NOT NULL

    GROUP BY
        z.Borough,
        z.Zone,
        hour
),

dropoffs AS (

    SELECT
        z.Borough,
        z.Zone,
        EXTRACT(HOUR FROM t.tpep_dropoff_datetime) AS hour,
        COUNT(*) AS dropoffs

    FROM final_trips t

    JOIN zone_lookup z
        ON t.DOLocationID = z.LocationID

    WHERE z.Zone IS NOT NULL

    GROUP BY
        z.Borough,
        z.Zone,
        hour
)

SELECT
    p.Borough,
    p.Zone,
    p.hour,
    p.pickups,
    COALESCE(d.dropoffs, 0) AS dropoffs,

    p.pickups -
    COALESCE(d.dropoffs, 0) AS net_pickups,

    ROUND(
        (
            p.pickups -
            COALESCE(d.dropoffs, 0)
        ) * 1.0
        /
        NULLIF(
            p.pickups +
            COALESCE(d.dropoffs, 0),
            0
        ),
        3
    ) AS imbalance_index

FROM pickups p

LEFT JOIN dropoffs d
    ON p.Borough = d.Borough
    AND p.Zone = d.Zone
    AND p.hour = d.hour

WHERE p.Zone NOT IN (
    'JFK Airport',
    'LaGuardia Airport'
)

ORDER BY imbalance_index DESC;



-- ============================================================
-- 11. TOP URBAN PICKUP-HEAVY ZONE-HOURS
-- ============================================================

WITH pickups AS (

    SELECT
        z.Zone,
        EXTRACT(HOUR FROM t.tpep_pickup_datetime) AS hour,
        COUNT(*) AS pickups

    FROM final_trips t

    JOIN zone_lookup z
        ON t.PULocationID = z.LocationID

    GROUP BY
        z.Zone,
        hour
),

dropoffs AS (

    SELECT
        z.Zone,
        EXTRACT(HOUR FROM t.tpep_dropoff_datetime) AS hour,
        COUNT(*) AS dropoffs

    FROM final_trips t

    JOIN zone_lookup z
        ON t.DOLocationID = z.LocationID

    GROUP BY
        z.Zone,
        hour
),

imbalance AS (

    SELECT
        p.Zone,
        p.hour,
        p.pickups,
        COALESCE(d.dropoffs, 0) AS dropoffs,

        (
            p.pickups -
            COALESCE(d.dropoffs, 0)
        ) * 1.0
        /
        NULLIF(
            p.pickups +
            COALESCE(d.dropoffs, 0),
            0
        ) AS imbalance_index

    FROM pickups p

    LEFT JOIN dropoffs d
        ON p.Zone = d.Zone
        AND p.hour = d.hour
)

SELECT
    Zone,
    hour,
    pickups,
    dropoffs,

    pickups - dropoffs AS net_pickups,

    ROUND(imbalance_index, 3)
        AS imbalance_index

FROM imbalance

WHERE Zone NOT IN (
    'JFK Airport',
    'LaGuardia Airport'
)

  AND pickups + dropoffs >= 5000

ORDER BY imbalance_index DESC

LIMIT 20;



-- ============================================================
-- 12. DAILY ROBUSTNESS CHECK
-- ============================================================

-- Selected operating windows identified during the analysis:
--
-- Greenwich Village South: late night (22:00–02:00)
-- Midtown Center: evening (17:00–00:00)
-- Penn Station/Madison Sq West: morning/daytime (06:00–13:00)


WITH selected_pickups AS (

    SELECT

        z.Zone AS zone_name,

        CASE

            -- Assign after-midnight Greenwich trips
            -- to the previous service night
            WHEN z.Zone = 'Greenwich Village South'
             AND EXTRACT(HOUR FROM t.tpep_pickup_datetime)
                 BETWEEN 0 AND 2
            THEN CAST(
                t.tpep_pickup_datetime AS DATE
            ) - INTERVAL 1 DAY

            -- Same logic for Midnight Center hour 0
            WHEN z.Zone = 'Midtown Center'
             AND EXTRACT(HOUR FROM t.tpep_pickup_datetime) = 0
            THEN CAST(
                t.tpep_pickup_datetime AS DATE
            ) - INTERVAL 1 DAY

            ELSE CAST(
                t.tpep_pickup_datetime AS DATE
            )

        END AS service_date,

        COUNT(*) AS pickups

    FROM final_trips t

    JOIN zone_lookup z
        ON t.PULocationID = z.LocationID

    WHERE

        (
            z.Zone = 'Greenwich Village South'
            AND (
                EXTRACT(HOUR FROM t.tpep_pickup_datetime) >= 22
                OR
                EXTRACT(HOUR FROM t.tpep_pickup_datetime) <= 2
            )
        )

        OR

        (
            z.Zone = 'Midtown Center'
            AND (
                EXTRACT(HOUR FROM t.tpep_pickup_datetime) >= 17
                OR
                EXTRACT(HOUR FROM t.tpep_pickup_datetime) = 0
            )
        )

        OR

        (
            z.Zone = 'Penn Station/Madison Sq West'
            AND EXTRACT(HOUR FROM t.tpep_pickup_datetime)
                BETWEEN 6 AND 13
        )

    GROUP BY
        zone_name,
        service_date
),

selected_dropoffs AS (

    SELECT

        z.Zone AS zone_name,

        CASE

            WHEN z.Zone = 'Greenwich Village South'
             AND EXTRACT(HOUR FROM t.tpep_dropoff_datetime)
                 BETWEEN 0 AND 2
            THEN CAST(
                t.tpep_dropoff_datetime AS DATE
            ) - INTERVAL 1 DAY

            WHEN z.Zone = 'Midtown Center'
             AND EXTRACT(HOUR FROM t.tpep_dropoff_datetime) = 0
            THEN CAST(
                t.tpep_dropoff_datetime AS DATE
            ) - INTERVAL 1 DAY

            ELSE CAST(
                t.tpep_dropoff_datetime AS DATE
            )

        END AS service_date,

        COUNT(*) AS dropoffs

    FROM final_trips t

    JOIN zone_lookup z
        ON t.DOLocationID = z.LocationID

    WHERE

        (
            z.Zone = 'Greenwich Village South'
            AND (
                EXTRACT(HOUR FROM t.tpep_dropoff_datetime) >= 22
                OR
                EXTRACT(HOUR FROM t.tpep_dropoff_datetime) <= 2
            )
        )

        OR

        (
            z.Zone = 'Midtown Center'
            AND (
                EXTRACT(HOUR FROM t.tpep_dropoff_datetime) >= 17
                OR
                EXTRACT(HOUR FROM t.tpep_dropoff_datetime) = 0
            )
        )

        OR

        (
            z.Zone = 'Penn Station/Madison Sq West'
            AND EXTRACT(HOUR FROM t.tpep_dropoff_datetime)
                BETWEEN 6 AND 13
        )

    GROUP BY
        zone_name,
        service_date
)

SELECT
    p.zone_name,
    p.service_date,
    p.pickups,
    d.dropoffs,

    ROUND(
        (
            p.pickups - d.dropoffs
        ) * 1.0
        /
        NULLIF(
            p.pickups + d.dropoffs,
            0
        ),
        3
    ) AS daily_imbalance

FROM selected_pickups p

JOIN selected_dropoffs d
    ON p.zone_name = d.zone_name
    AND p.service_date = d.service_date

ORDER BY
    p.zone_name,
    p.service_date;



-- ============================================================
-- 13. TABLEAU EXPORT DATASET
-- ============================================================

WITH pickups AS (

    SELECT
        z.Borough,
        z.Zone,
        EXTRACT(HOUR FROM t.tpep_pickup_datetime) AS hour,
        COUNT(*) AS pickups

    FROM final_trips t

    JOIN zone_lookup z
        ON t.PULocationID = z.LocationID

    WHERE z.Zone IS NOT NULL
      AND z.Zone NOT IN (
          'JFK Airport',
          'LaGuardia Airport'
      )

    GROUP BY
        z.Borough,
        z.Zone,
        hour
),

dropoffs AS (

    SELECT
        z.Borough,
        z.Zone,
        EXTRACT(HOUR FROM t.tpep_dropoff_datetime) AS hour,
        COUNT(*) AS dropoffs

    FROM final_trips t

    JOIN zone_lookup z
        ON t.DOLocationID = z.LocationID

    WHERE z.Zone IS NOT NULL
      AND z.Zone NOT IN (
          'JFK Airport',
          'LaGuardia Airport'
      )

    GROUP BY
        z.Borough,
        z.Zone,
        hour
),

zone_totals AS (

    SELECT
        Borough,
        Zone,
        SUM(pickups) AS zone_total_pickups

    FROM pickups

    GROUP BY
        Borough,
        Zone
),

city_hourly AS (

    SELECT
        hour,
        SUM(pickups) AS city_hour_pickups

    FROM pickups

    GROUP BY hour
),

city_total AS (

    SELECT
        SUM(pickups) AS city_total_pickups

    FROM pickups
)

SELECT
    p.Borough,
    p.Zone,
    p.hour,
    p.pickups,
    COALESCE(d.dropoffs, 0) AS dropoffs,

    p.pickups +
    COALESCE(d.dropoffs, 0)
        AS total_activity,

    ROUND(
        (
            p.pickups -
            COALESCE(d.dropoffs, 0)
        ) * 1.0
        /
        NULLIF(
            p.pickups +
            COALESCE(d.dropoffs, 0),
            0
        ),
        4
    ) AS imbalance_index,

    ROUND(
        (
            p.pickups * 1.0 /
            zt.zone_total_pickups
        )
        /
        (
            ch.city_hour_pickups * 1.0 /
            ct.city_total_pickups
        ),
        4
    ) AS over_index

FROM pickups p

LEFT JOIN dropoffs d
    ON p.Borough = d.Borough
    AND p.Zone = d.Zone
    AND p.hour = d.hour

JOIN zone_totals zt
    ON p.Borough = zt.Borough
    AND p.Zone = zt.Zone

JOIN city_hourly ch
    ON p.hour = ch.hour

CROSS JOIN city_total ct

ORDER BY
    p.Borough,
    p.Zone,
    p.hour;
