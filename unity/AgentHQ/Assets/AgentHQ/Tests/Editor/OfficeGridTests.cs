using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

/// <summary>Port of the navigation checks in tests/run_tests.gd (lines 48-61).</summary>
public class OfficeGridTests
{
    [Test]
    public void EveryHomeReachesEverySeat()
    {
        foreach (Vector2Int start in OfficeGrid.Homes)
        {
            foreach (Vector2Int goal in OfficeGrid.Seats)
            {
                List<Vector2Int> path = OfficeGrid.Route(start, goal);
                Assert.IsNotEmpty(path, $"Every home must reach every meeting seat ({start} -> {goal})");
                Assert.AreEqual(start, path[0], "Path starts at the origin tile");
                Assert.AreEqual(goal, path[path.Count - 1], "Path ends at the destination tile");
                for (int i = 0; i < path.Count; i++)
                {
                    Assert.IsFalse(OfficeGrid.IsSolid(path[i]), $"Path crosses wall or furniture at {path[i]}");
                    if (i == 0) continue;
                    Vector2Int diff = path[i] - path[i - 1];
                    Assert.AreEqual(1, Mathf.Abs(diff.x) + Mathf.Abs(diff.y), "Path must use adjacent tiles");
                }
            }
        }
    }

    [Test]
    public void InvalidStartRejected()
    {
        Assert.IsEmpty(OfficeGrid.Route(new Vector2Int(-1, -1), OfficeGrid.Seats[0]));
        Assert.IsEmpty(OfficeGrid.Route(OfficeGrid.Homes[0], new Vector2Int(OfficeGrid.Width, 0)));
    }

    [Test]
    public void DeskNotWalkable()
    {
        Assert.IsEmpty(OfficeGrid.Route(OfficeGrid.Homes[0], new Vector2Int(4, 3)), "Desk is not walkable");
        Assert.IsTrue(OfficeGrid.IsSolid(new Vector2Int(4, 3)));
    }

    [Test]
    public void CorridorsAndRoomsAreFloor()
    {
        Assert.IsTrue(OfficeGrid.IsFloor(new Vector2Int(9, 0)));
        Assert.IsTrue(OfficeGrid.IsFloor(new Vector2Int(0, 7)));
        Assert.IsFalse(OfficeGrid.IsFloor(new Vector2Int(0, 0)));
        Assert.AreEqual(-1, OfficeGrid.RoomAt(new Vector2Int(9, 7)));
        for (int i = 0; i < OfficeGrid.Homes.Length; i++) Assert.AreEqual(i, OfficeGrid.RoomAt(OfficeGrid.Homes[i]));
        foreach (Vector2Int seat in OfficeGrid.Seats) Assert.AreEqual(2, OfficeGrid.RoomAt(seat));
    }

    [Test]
    public void ReservedTilesAreAvoided()
    {
        var from = new Vector2Int(4, 4);
        var to = new Vector2Int(4, 6);
        var blocked = new HashSet<Vector2Int> { new Vector2Int(4, 5) };
        List<Vector2Int> path = OfficeGrid.Route(from, to, blocked);
        Assert.IsNotEmpty(path);
        CollectionAssert.DoesNotContain(path, new Vector2Int(4, 5));
        Assert.IsEmpty(OfficeGrid.Route(from, to, new HashSet<Vector2Int> { to }), "Blocked destination is unreachable");
    }

    [Test]
    public void RouteToSelfIsSingleTile()
    {
        List<Vector2Int> path = OfficeGrid.Route(OfficeGrid.Homes[1], OfficeGrid.Homes[1]);
        Assert.AreEqual(1, path.Count);
        Assert.AreEqual(OfficeGrid.Homes[1], path[0]);
    }
}
