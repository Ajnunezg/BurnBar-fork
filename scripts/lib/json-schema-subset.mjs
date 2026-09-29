/**
 * The draft-07 subset the repo's evidence receipts use
 * (docs/schemas/*-receipt.schema.json). Unsupported keywords throw instead of
 * being skipped, so a schema cannot gain a rule this validator silently
 * ignores. Shared by scripts/ops/firestore-restore-drill-verify.mjs and
 * scripts/ops/rollback-drill-evidence.mjs.
 */

export const RFC3339 = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/u;

const SCHEMA_ANNOTATIONS = new Set(["$schema", "$id", "title", "description"]);
const SCHEMA_KEYWORDS = new Set([
  "type", "const", "enum", "required", "properties", "additionalProperties", "items", "minItems",
  "maxItems", "contains", "minimum", "minLength", "maxLength", "pattern", "format", "oneOf",
  "allOf", "if", "then", "else",
]);

export function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasType(value, type) {
  if (type === "object") return isObject(value);
  if (type === "array") return Array.isArray(value);
  if (type === "integer") return Number.isInteger(value);
  if (type === "number") return Number.isFinite(value);
  if (type === "null") return value === null;
  return typeof value === type;
}

function assertSupportedSchema(schema, path) {
  const unsupported = Object.keys(schema).find(
    (keyword) => !SCHEMA_KEYWORDS.has(keyword) && !SCHEMA_ANNOTATIONS.has(keyword),
  );
  if (unsupported !== undefined) throw new Error(`unsupported JSON Schema keyword "${unsupported}" at ${path}`);
  if (schema.additionalProperties !== undefined && schema.additionalProperties !== false) {
    throw new Error(`only "additionalProperties": false is supported (at ${path})`);
  }
  if (schema.format !== undefined && schema.format !== "date-time") {
    throw new Error(`only "format": "date-time" is supported (at ${path})`);
  }
}

/** Validate `value` against the supported draft-07 subset; returns error strings. */
export function validateAgainstSchema(value, schema, path = "$") {
  assertSupportedSchema(schema, path);
  if (schema.type !== undefined) {
    const types = [schema.type].flat();
    if (!types.some((type) => hasType(value, type))) return [`${path} must be ${types.join(" or ")}`];
  }
  const errors = [];
  const check = (condition, message) => {
    if (!condition) errors.push(`${path} ${message}`);
  };
  if ("const" in schema) check(value === schema.const, `must be ${JSON.stringify(schema.const)}`);
  if (schema.enum) check(schema.enum.includes(value), `must be one of ${schema.enum.join(", ")}`);
  if (typeof value === "string") {
    check(value.length >= (schema.minLength ?? 0), `is shorter than ${schema.minLength}`);
    check(value.length <= (schema.maxLength ?? Infinity), `is longer than ${schema.maxLength}`);
    if (schema.pattern) check(new RegExp(schema.pattern, "u").test(value), `does not match ${schema.pattern}`);
    if (schema.format) check(RFC3339.test(value) && Number.isFinite(Date.parse(value)), "is not an RFC 3339 date-time");
  }
  if (typeof value === "number") check(value >= (schema.minimum ?? -Infinity), `is below ${schema.minimum}`);
  if (Array.isArray(value)) {
    check(value.length >= (schema.minItems ?? 0), `has fewer than ${schema.minItems} items`);
    check(value.length <= (schema.maxItems ?? Infinity), `has more than ${schema.maxItems} items`);
    if (schema.items) {
      value.forEach((item, index) => errors.push(...validateAgainstSchema(item, schema.items, `${path}[${index}]`)));
    }
    if (schema.contains) {
      check(value.some((item) => validateAgainstSchema(item, schema.contains).length === 0), "has no item matching its contains rule");
    }
  }
  if (isObject(value)) {
    for (const key of schema.required ?? []) check(Object.hasOwn(value, key), `is missing ${key}`);
    for (const [key, child] of Object.entries(value)) {
      if (schema.properties && Object.hasOwn(schema.properties, key)) {
        errors.push(...validateAgainstSchema(child, schema.properties[key], `${path}.${key}`));
      } else {
        check(schema.additionalProperties !== false, `has unexpected property ${key}`);
      }
    }
  }
  for (const branch of schema.allOf ?? []) errors.push(...validateAgainstSchema(value, branch, path));
  if (schema.oneOf) {
    const matched = schema.oneOf.filter((branch) => validateAgainstSchema(value, branch, path).length === 0).length;
    check(matched === 1, `matches ${matched} oneOf branches, expected exactly 1`);
  }
  if (schema.if) {
    const branch = validateAgainstSchema(value, schema.if, path).length === 0 ? schema.then : schema.else;
    if (branch) errors.push(...validateAgainstSchema(value, branch, path));
  }
  return errors;
}
