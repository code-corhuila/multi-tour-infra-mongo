// Instance-level setup: the connection user of the identity_audit database (Annex J, J.4, J.7).
// The image runs it once, on an empty volume. Run it by hand when a domain is added (J.5.5), so it
// must be safe to repeat: a user that exists keeps its password. Collections, validators, indexes
// and roles belong to multi-tour-identity-audit-db, not to this script.
const password = process.env.IDENTITY_AUDIT_APP_PASSWORD;
if (!password) {
  throw new Error('IDENTITY_AUDIT_APP_PASSWORD is required, set it in env/<environment>.env');
}

const target = db.getSiblingDB('identity_audit');
if (!target.getUser('identity_audit_app')) {
  target.createUser({
    user: 'identity_audit_app',
    pwd: password,
    roles: [{ role: 'readWrite', db: 'identity_audit' }],
  });
}
