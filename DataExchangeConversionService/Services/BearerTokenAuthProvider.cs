using System.Security.Cryptography;
using System.Text;
using Autodesk.DataExchange.Core.Interface;
using Autodesk.DataExchange.Core.Models;

namespace DataExchangeViewingService.Services;

public sealed class BearerTokenAuthProvider : IAuth
{
    private readonly string _bearerToken;

    public BearerTokenAuthProvider(string bearerToken)
    {
        _bearerToken = bearerToken;
    }

    public Task<string> GetAuthTokenAsync()
    {
        return Task.FromResult(_bearerToken);
    }

    public string GetAuthToken(bool forceRefresh)
    {
        return _bearerToken;
    }

    public Task<UserAccount> GetUserAccountAsync()
    {
        return Task.FromResult(new UserAccount
        {
            UserId = CreateStableUserId(_bearerToken),
            Email = string.Empty,
            FirstName = string.Empty,
            LastName = string.Empty,
            ThumbnailURL = string.Empty
        });
    }

    private static string CreateStableUserId(string bearerToken)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(bearerToken));
        return Convert.ToHexString(hash);
    }
}