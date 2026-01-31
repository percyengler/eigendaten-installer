# Keycloak Profilfelder + OIDC-Mapper

## Uebersicht

Keycloak wird mit 4 benutzerdefinierten Profilfeldern konfiguriert, die ueber OIDC-Mapper als Claims an alle verbundenen Dienste weitergegeben werden.

## Profilfelder

| Feld | Attribut-Name | Anzeigename | Claim | Scope |
|------|--------------|-------------|-------|-------|
| Telefon | `phoneNumber` | Telefon | `phone_number` | phone |
| Mobiltelefon | `mobileNumber` | Mobiltelefon | `mobile_number` | profile |
| Abteilung | `department` | Abteilung | `department` | profile |
| Position | `jobTitle` | Position | `job_title` | profile |

## Architektur

```
Keycloak User-Attribute
        |
        v
OIDC Protocol Mapper (User Attribute -> Token Claim)
        |
        v
ID Token / Access Token / UserInfo
        |
        v
Nextcloud user_oidc / Paperless allauth / etc.
```

## Konfiguration

### 1. Deutsch als Standard-Sprache

```bash
docker exec keycloak /opt/keycloak/bin/kcadm.sh update realms/${REALM} \
    -s 'internationalizationEnabled=true' \
    -s 'supportedLocales=["de","en"]' \
    -s 'defaultLocale=de'
```

### 2. User Profile Attribute (Keycloak 26+)

Keycloak 26+ nutzt die User Profile API fuer Attribut-Definitionen. Siehe `04-sso-setup.sh` fuer die vollstaendige JSON-Konfiguration.

### 3. OIDC Protocol Mapper

Fuer jedes benutzerdefinierte Attribut wird ein Mapper im entsprechenden Scope erstellt:

```bash
docker exec keycloak /opt/keycloak/bin/kcadm.sh create \
    client-scopes/${SCOPE_ID}/protocol-mappers/models \
    -r ${REALM} \
    -s name=department \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-usermodel-attribute-mapper \
    -s 'config={
        "user.attribute": "department",
        "claim.name": "department",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "jsonType.label": "String"
    }'
```

### 4. Phone Scope als Default

Der `phone` Scope muss explizit von optional zu default verschoben werden:

```bash
# 1. Aus optional-scopes entfernen
docker exec keycloak /opt/keycloak/bin/kcadm.sh delete \
    clients/${CLIENT_ID}/optional-client-scopes/${PHONE_SCOPE_ID} -r ${REALM}

# 2. Als default-scope hinzufuegen
docker exec keycloak /opt/keycloak/bin/kcadm.sh update \
    clients/${CLIENT_ID}/default-client-scopes/${PHONE_SCOPE_ID} -r ${REALM}
```

## Testen

### Token decodieren

```bash
TOKEN=$(curl -s -X POST "${KC_URL}/realms/${REALM}/protocol/openid-connect/token" \
    -d "client_id=nextcloud" -d "client_secret=${SECRET}" \
    -d "username=testuser" -d "password=testpass" \
    -d "grant_type=password" | jq -r '.access_token')

echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```

Erwartete Claims:

```json
{
  "preferred_username": "gf-leiter",
  "email": "gf@example.de",
  "phone_number": "+49 5321 12345",
  "mobile_number": "+49 170 1234567",
  "department": "Geschaeftsfuehrung",
  "job_title": "Geschaeftsfuehrer"
}
```

## Bekannte Einschraenkungen

1. **Nextcloud user_oidc** mappt nur username, displayName und email. Benutzerdefinierte Claims erfordern Custom-Apps.
2. **Paperless allauth** nutzt nur username und email.
3. **Phone Scope** muss explizit als Default gesetzt werden.
4. **Keycloak 26+** nutzt die neue User Profile API. Aeltere Versionen brauchen andere Konfiguration.

## Referenz

- [Keycloak User Profile](https://www.keycloak.org/docs/latest/server_admin/#user-profile)
- [Keycloak Protocol Mappers](https://www.keycloak.org/docs/latest/server_admin/#_protocol-mappers)
- [Nextcloud user_oidc](https://github.com/nextcloud/user_oidc)
