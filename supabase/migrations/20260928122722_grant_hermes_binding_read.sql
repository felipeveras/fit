-- The final blanket REVOKE in the preceding migration removed this grant.
-- RLS still restricts Hermes to its own enabled binding.
grant select on integration.service_user_bindings to hermes_coach;
