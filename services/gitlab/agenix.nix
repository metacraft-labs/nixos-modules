secretsDir: {
  "gitlab/db" = {
    file = "${secretsDir}/db.age";
    owner = "gitlab";
    group = "gitlab";
  };
  "gitlab/db_password" = {
    file = "${secretsDir}/db_password.age";
    owner = "gitlab";
    group = "gitlab";
  };
  "gitlab/root_password" = {
    file = "${secretsDir}/root_password.age";
    owner = "gitlab";
    group = "gitlab";
  };
  "gitlab/secret" = {
    file = "${secretsDir}/secret.age";
    owner = "gitlab";
    group = "gitlab";
  };
  "gitlab/otp" = {
    file = "${secretsDir}/otp.age";
    owner = "gitlab";
    group = "gitlab";
  };
  "gitlab/jws" = {
    file = "${secretsDir}/jws.age";
    owner = "gitlab";
    group = "gitlab";
  };
  "gitlab/smtp_password" = {
    file = "${secretsDir}/smtp_password.age";
    owner = "gitlab";
    group = "gitlab";
  };
}
