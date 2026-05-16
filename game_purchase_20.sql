DECLARE @BuyerId INT = 1;

INSERT INTO GamePurchase
(
    PublicId,
    UserId,
    GameId,
    DataGamePurchase,
    FinalPrice,
    PromotionValue,
    PromotionId,
    StatusPurchase,
    CreatedAt,
    CreatedBy
)
SELECT
    NEWID(),
    @BuyerId,
    v.GameId,
    DATEADD(MINUTE, (v.GameId - 1) * 5, '2026-05-13T10:00:00'),
    27.03 + ((v.GameId - 1) * 7.13),
    NULL,
    NULL,
    'Approved',
    SYSUTCDATETIME(),
    1
FROM
(
    VALUES
    (1),(2),(3),(4),(5),
    (6),(7),(8),(9),(10),
    (11),(12),(13),(14),(15),
    (16),(17),(18),(19),(20)
) v(GameId);