import domain/raa
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import message/reciever/models/cap as models_cap

pub fn oid_from_guid_test() {
  raa.oid_from_guid("urn:oid:2.49.0.0.288.0")
  |> should.equal(Ok("2.49.0.0.288.0"))

  raa.oid_from_guid("2.49.0.0.288.0")
  |> should.equal(Ok("2.49.0.0.288.0"))

  raa.oid_from_guid("   urn:oid:2.49.0.0.276.0   ")
  |> should.equal(Ok("2.49.0.0.276.0"))

  // Empty or containing colon (outside urn:oid:) is dropped
  raa.oid_from_guid("")
  |> should.equal(Error(Nil))

  raa.oid_from_guid("urn:oid:")
  |> should.equal(Error(Nil))

  raa.oid_from_guid("urn:oid:2.49:0.0")
  |> should.equal(Error(Nil))
}

pub fn split_title_test() {
  // First ": " splits country and name
  raa.split_title("Ghana: Ghana Meteorological Agency")
  |> should.equal(#("Ghana", "Ghana Meteorological Agency"))

  // Multiple colons: splits at the FIRST ": "
  raa.split_title("Country: Dept: Sub-dept")
  |> should.equal(#("Country", "Dept: Sub-dept"))

  // Absent colon: country_name = title and name = title
  raa.split_title("Deutscher Wetterdienst")
  |> should.equal(#("Deutscher Wetterdienst", "Deutscher Wetterdienst"))
}

pub fn parse_categories_test() {
  // Description with categories and trailing dot
  let desc1 = "A WMO Member [Ghana] identifies … CAP categories:  Met."
  raa.parse_categories(desc1)
  |> should.equal(["Met"])

  // Multiple categories with trailing dot
  let desc2 = "…for hazard threats of these CAP categories:  Met Other."
  raa.parse_categories(desc2)
  |> should.equal(["Met", "Other"])

  // Categories without trailing dot
  let desc3 = "threats of categories: Geo Safety"
  raa.parse_categories(desc3)
  |> should.equal(["Geo", "Safety"])

  // No categories mentioned
  let desc4 = "No categories in this text."
  raa.parse_categories(desc4)
  |> should.equal([])
}

pub fn parse_authority_fixtures_test() {
  // Ghana fixture (§2, §5.1)
  let ghana_item =
    models_cap.RegistryItem(
      guid: "urn:oid:2.49.0.0.288.0",
      title: Some("Ghana: Ghana Meteorological Agency"),
      country_iso3: Some("GHA"),
      link: Some("https://alertingauthority.wmo.int/authorities.php?recId=318"),
      description: Some(
        "A WMO Member [Ghana] identifies … CAP categories:  Met.",
      ),
      pub_date: Some("Thu, 17 Sep 2026 05:57:50 +0000"),
      abbrev: Some("gmet"),
      feeds: [
        models_cap.RegistryFeed(
          url: "https://www.meteo.gov.gh/api/cap/rss.xml",
          language: Some("en"),
        ),
      ],
    )

  let assert Ok(ghana) = raa.parse_authority(ghana_item)
  ghana.oid |> should.equal("2.49.0.0.288.0")
  ghana.country_name |> should.equal("Ghana")
  ghana.name |> should.equal("Ghana Meteorological Agency")
  ghana.country_iso3 |> should.equal("GHA")
  ghana.categories |> should.equal(["Met"])
  ghana.source.id |> should.equal("cap-2.49.0.0.288.0")
  ghana.source.attribution_text
  |> should.equal(
    "Ghana Meteorological Agency (Ghana), via the WMO Register of Alerting Authorities",
  )
  ghana.source.priority |> should.equal(70)
  ghana.source.redistributable |> should.equal(False)

  // Colombia fixture
  let colombia_item =
    models_cap.RegistryItem(
      guid: "urn:oid:2.49.0.0.170.0",
      title: Some("Colombia: IDEAM"),
      country_iso3: Some("COL"),
      link: Some("https://alertingauthority.wmo.int/authorities.php?recId=170"),
      description: Some("CAP categories: Met Hydro."),
      pub_date: Some("Fri, 18 Sep 2026 12:00:00 +0000"),
      abbrev: Some("ideam"),
      feeds: [],
    )
  let assert Ok(colombia) = raa.parse_authority(colombia_item)
  colombia.country_name |> should.equal("Colombia")
  colombia.categories |> should.equal(["Met", "Hydro"])

  // Cyprus fixture
  let cyprus_item =
    models_cap.RegistryItem(
      guid: "urn:oid:2.49.0.0.196.0",
      title: Some("Cyprus: Department of Meteorology"),
      country_iso3: Some("CYP"),
      link: None,
      description: None,
      pub_date: None,
      abbrev: None,
      feeds: [],
    )
  let assert Ok(cyprus) = raa.parse_authority(cyprus_item)
  cyprus.country_name |> should.equal("Cyprus")
  cyprus.categories |> should.equal([])
}

pub fn primary_language_subtag_test() {
  raa.primary_language_subtag(Some("en")) |> should.equal("en")
  raa.primary_language_subtag(Some("en-GB")) |> should.equal("en")
  raa.primary_language_subtag(Some("EN")) |> should.equal("en")
  raa.primary_language_subtag(Some("fr-CA")) |> should.equal("fr")
  raa.primary_language_subtag(Some("de_DE")) |> should.equal("de")
  raa.primary_language_subtag(Some("")) |> should.equal("en")
  raa.primary_language_subtag(None) |> should.equal("en")
}

pub fn nws_host_exclusion_test() {
  // alerts.weather.gov (http and https, with paths)
  raa.is_nws_url("http://alerts.weather.gov") |> should.equal(True)
  raa.is_nws_url("https://alerts.weather.gov/cap/all.atom")
  |> should.equal(True)
  raa.is_nws_url("https://ALERTS.WEATHER.GOV/path?query=1")
  |> should.equal(True)

  // api.weather.gov (http and https, with paths and ports)
  raa.is_nws_url("http://api.weather.gov/alerts/active.atom")
  |> should.equal(True)
  raa.is_nws_url("https://api.weather.gov:443/alerts")
  |> should.equal(True)

  // Non-NWS hosts
  raa.is_nws_url("https://opendata.dwd.de/weather/alerts/cap/rss.xml")
  |> should.equal(False)
  raa.is_nws_url("https://example.weather.gov/cap") |> should.equal(False)
}

pub fn dwd_multi_language_feed_selection_test() {
  // DWD authority lists German and English feeds
  let dwd_authority =
    raa.ParsedAuthority(
      oid: "2.49.0.0.276.0",
      source: raa.make_authority_source(
        "2.49.0.0.276.0",
        "Deutscher Wetterdienst",
        "Germany",
        None,
      ),
      name: "Deutscher Wetterdienst",
      country_name: "Germany",
      country_iso3: "DEU",
      abbrev: Some("DWD"),
      register_url: None,
      categories: ["Met"],
      pub_date: None,
      feeds: [
        models_cap.RegistryFeed(
          url: "https://opendata.dwd.de/weather/alerts/cap/de.xml",
          language: Some("de"),
        ),
        models_cap.RegistryFeed(
          url: "https://opendata.dwd.de/weather/alerts/cap/en.xml",
          language: Some("en"),
        ),
      ],
    )

  let result = raa.select_feeds([dwd_authority], [], [])
  let assert [de_feed, en_feed] = result.feeds

  // German feed is excluded due to language (English available)
  de_feed.url
  |> should.equal("https://opendata.dwd.de/weather/alerts/cap/de.xml")
  de_feed.subscribed |> should.equal(False)
  de_feed.exclusion_reason |> should.equal(Some("language"))

  // English feed is subscribed
  en_feed.url
  |> should.equal("https://opendata.dwd.de/weather/alerts/cap/en.xml")
  en_feed.subscribed |> should.equal(True)
  en_feed.exclusion_reason |> should.equal(None)
}

pub fn multi_lister_url_feed_selection_test() {
  let shared_url = "https://example.org/shared_cap.xml"

  // Authority 1 only lists the shared feed in French
  let auth1 =
    raa.ParsedAuthority(
      oid: "2.49.0.0.1.0",
      source: raa.make_authority_source("2.49.0.0.1.0", "Auth 1", "C1", None),
      name: "Auth 1",
      country_name: "C1",
      country_iso3: "C1X",
      abbrev: None,
      register_url: None,
      categories: [],
      pub_date: None,
      feeds: [models_cap.RegistryFeed(url: shared_url, language: Some("fr"))],
    )

  // Authority 2 lists shared feed in French, PLUS an English feed
  let auth2 =
    raa.ParsedAuthority(
      oid: "2.49.0.0.2.0",
      source: raa.make_authority_source("2.49.0.0.2.0", "Auth 2", "C2", None),
      name: "Auth 2",
      country_name: "C2",
      country_iso3: "C2X",
      abbrev: None,
      register_url: None,
      categories: [],
      pub_date: None,
      feeds: [
        models_cap.RegistryFeed(url: shared_url, language: Some("fr")),
        models_cap.RegistryFeed(
          url: "https://example.org/auth2_en.xml",
          language: Some("en"),
        ),
      ],
    )

  let result = raa.select_feeds([auth1, auth2], [], [])
  let assert [shared_feed, _] = result.feeds

  // Owner is Auth 1 (first in document order)
  shared_feed.authority_oid |> should.equal("2.49.0.0.1.0")
  shared_feed.authority_oids |> should.equal(["2.49.0.0.1.0", "2.49.0.0.2.0"])

  // Excluded ONLY if every lister excludes it: Auth 1 has no EN feed, so does not exclude it.
  // Therefore shared_feed is subscribed!
  shared_feed.subscribed |> should.equal(True)
  shared_feed.exclusion_reason |> should.equal(None)
}

pub fn removed_feeds_and_authorities_test() {
  let auth =
    raa.ParsedAuthority(
      oid: "2.49.0.0.100.0",
      source: raa.make_authority_source(
        "2.49.0.0.100.0",
        "Active Auth",
        "Active",
        None,
      ),
      name: "Active Auth",
      country_name: "Active",
      country_iso3: "ACT",
      abbrev: None,
      register_url: None,
      categories: [],
      pub_date: None,
      feeds: [
        models_cap.RegistryFeed(
          url: "https://example.org/active.xml",
          language: Some("en"),
        ),
      ],
    )

  let db_feed_urls = [
    "https://example.org/active.xml",
    "https://example.org/old_removed_feed.xml",
  ]
  let db_authority_oids = ["2.49.0.0.100.0", "2.49.0.0.999.0"]

  let result = raa.select_feeds([auth], db_feed_urls, db_authority_oids)

  result.removed_feed_urls
  |> should.equal(["https://example.org/old_removed_feed.xml"])
  result.removed_authority_oids
  |> should.equal(["2.49.0.0.999.0"])
}

pub fn poll_interval_boundaries_test() {
  // < 3 failures -> 300 s
  raa.poll_interval_seconds(0) |> should.equal(300)
  raa.poll_interval_seconds(1) |> should.equal(300)
  raa.poll_interval_seconds(2) |> should.equal(300)

  // 3..9 failures -> 3600 s
  raa.poll_interval_seconds(3) |> should.equal(3600)
  raa.poll_interval_seconds(5) |> should.equal(3600)
  raa.poll_interval_seconds(9) |> should.equal(3600)

  // >= 10 failures -> 21600 s
  raa.poll_interval_seconds(10) |> should.equal(21_600)
  raa.poll_interval_seconds(15) |> should.equal(21_600)
}

pub fn feed_health_classification_test() {
  let now = timestamp.system_time()
  let ten_days_ago = timestamp.subtract(now, duration.hours(10 * 24))
  let thirty_one_days_ago = timestamp.subtract(now, duration.hours(31 * 24))

  // Excluded if not subscribed
  raa.classify_feed_health(False, Some(now), 0, Some(10), Some(now), now)
  |> should.equal(raa.HealthExcluded)

  // Pending if never polled
  raa.classify_feed_health(True, None, 0, None, None, now)
  |> should.equal(raa.HealthPending)

  // Failing if consecutive_failures >= 3
  raa.classify_feed_health(True, Some(now), 3, Some(10), Some(now), now)
  |> should.equal(raa.HealthFailing)

  // Degraded if consecutive_failures == 1 or 2 (last poll failed)
  raa.classify_feed_health(True, Some(now), 1, Some(10), Some(now), now)
  |> should.equal(raa.HealthDegraded)

  // Stale if newest_item_at is older than 30 days
  raa.classify_feed_health(
    True,
    Some(now),
    0,
    Some(5),
    Some(thirty_one_days_ago),
    now,
  )
  |> should.equal(raa.HealthStale)

  // Empty if item_count == 0 (and not stale)
  raa.classify_feed_health(True, Some(now), 0, Some(0), None, now)
  |> should.equal(raa.HealthEmpty)

  // Healthy Ok when recent items and no failures
  raa.classify_feed_health(
    True,
    Some(now),
    0,
    Some(10),
    Some(ten_days_ago),
    now,
  )
  |> should.equal(raa.HealthOk)
}

pub fn feed_health_stale_boundary_test() {
  let now = timestamp.system_time()

  // Exactly 30 days ago: diff = 2_592_000 seconds, NOT > 2_592_000 → HealthOk
  let exactly_thirty_days_ago =
    timestamp.subtract(now, duration.seconds(2_592_000))
  raa.classify_feed_health(
    True,
    Some(now),
    0,
    Some(5),
    Some(exactly_thirty_days_ago),
    now,
  )
  |> should.equal(raa.HealthOk)

  // 30 days + 1 second ago: diff = 2_592_001 → HealthStale
  let just_over_thirty_days =
    timestamp.subtract(now, duration.seconds(2_592_001))
  raa.classify_feed_health(
    True,
    Some(now),
    0,
    Some(5),
    Some(just_over_thirty_days),
    now,
  )
  |> should.equal(raa.HealthStale)
}

pub fn select_feeds_nws_url_test() {
  // An authority whose only feed is an NWS URL → excluded with reason "nws"
  let nws_auth =
    raa.ParsedAuthority(
      oid: "2.49.0.0.840.0",
      source: raa.make_authority_source(
        "2.49.0.0.840.0",
        "NWS",
        "United States",
        None,
      ),
      name: "NWS",
      country_name: "United States",
      country_iso3: "USA",
      abbrev: Some("nws"),
      register_url: None,
      categories: ["Met"],
      pub_date: None,
      feeds: [
        models_cap.RegistryFeed(
          url: "https://alerts.weather.gov/cap/us.php?x=1",
          language: Some("en"),
        ),
      ],
    )

  let result = raa.select_feeds([nws_auth], [], [])
  let assert [nws_feed] = result.feeds
  nws_feed.subscribed |> should.equal(False)
  nws_feed.exclusion_reason |> should.equal(Some("nws"))
}

pub fn select_feeds_all_listers_exclude_by_language_test() {
  // URL where EVERY lister has both en and non-en feeds → all exclude the non-en URL
  let auth_a =
    raa.ParsedAuthority(
      oid: "2.49.0.0.10.0",
      source: raa.make_authority_source("2.49.0.0.10.0", "Auth A", "C1", None),
      name: "Auth A",
      country_name: "C1",
      country_iso3: "C1X",
      abbrev: None,
      register_url: None,
      categories: [],
      pub_date: None,
      feeds: [
        models_cap.RegistryFeed(
          url: "https://example.org/shared_fr.xml",
          language: Some("fr"),
        ),
        models_cap.RegistryFeed(
          url: "https://example.org/auth_a_en.xml",
          language: Some("en"),
        ),
      ],
    )

  let auth_b =
    raa.ParsedAuthority(
      oid: "2.49.0.0.11.0",
      source: raa.make_authority_source("2.49.0.0.11.0", "Auth B", "C2", None),
      name: "Auth B",
      country_name: "C2",
      country_iso3: "C2X",
      abbrev: None,
      register_url: None,
      categories: [],
      pub_date: None,
      feeds: [
        models_cap.RegistryFeed(
          url: "https://example.org/shared_fr.xml",
          language: Some("fr"),
        ),
        models_cap.RegistryFeed(
          url: "https://example.org/auth_b_en.xml",
          language: Some("en"),
        ),
      ],
    )

  let result = raa.select_feeds([auth_a, auth_b], [], [])

  // shared_fr.xml: both auth_a and auth_b have en feeds → both exclude the fr URL → excluded
  let fr_feed =
    list.find(result.feeds, fn(f) {
      f.url == "https://example.org/shared_fr.xml"
    })
  let assert Ok(fr) = fr_feed
  fr.subscribed |> should.equal(False)
  fr.exclusion_reason |> should.equal(Some("language"))

  // en feeds are subscribed
  let en_a =
    list.find(result.feeds, fn(f) {
      f.url == "https://example.org/auth_a_en.xml"
    })
  let assert Ok(ea) = en_a
  ea.subscribed |> should.equal(True)

  let en_b =
    list.find(result.feeds, fn(f) {
      f.url == "https://example.org/auth_b_en.xml"
    })
  let assert Ok(eb) = en_b
  eb.subscribed |> should.equal(True)
}
